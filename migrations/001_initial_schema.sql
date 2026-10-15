-- FlowGuard — migración de referencia del esquema inicial
--
-- Vive en el repositorio "flowguard-supabase" (FlowGuard-Hackathon), uno de
-- varios repos independientes del proyecto. Todo comentario de este archivo
-- que diga "docs/algo.md" se refiere a ese archivo dentro del repositorio
-- hermano https://github.com/FlowGuard-Hackathon/flowguard-docs — es la
-- fuente de verdad si hay alguna discrepancia con este SQL.
--
-- IMPORTANTE: este archivo es un ARTEFACTO DOCUMENTAL. **No se ha ejecutado
-- contra ningún proyecto Supabase real** desde este repositorio; la
-- diferencia entre Supabase y un PostgreSQL genérico importa (extensiones
-- preinstaladas, roles anon/authenticated/service_role reales, políticas de
-- Supabase Auth) y solo un proyecto Supabase real la confirma.
-- El repositorio `flowguard-app`/`flowguard-src` (o el `flowguard` combinado)
-- debe copiar (y versionar de forma propia) este archivo en su carpeta
-- supabase/migrations/ y ejecutarlo con `supabase db push` o el mecanismo de
-- migraciones que el equipo adopte, y validar ahí mismo el comportamiento de
-- anon/service_role.
--
-- Lo que SÍ se verificó (segunda auditoría, 2026-10-15): este archivo se
-- ejecutó completo, sin editar, contra un contenedor Docker con PostgreSQL 16
-- genérico (`postgres:16-alpine`) desechado inmediatamente después de la
-- prueba. Se confirmó que: las 32 sentencias se ejecutan en orden sin error;
-- las 10 tablas quedan creadas con RLS habilitado; los índices parciales de
-- investigation_attempts se crean correctamente; la restricción
-- UNIQUE (idempotency_key, scenario_id) rechaza una clave duplicada; y el
-- fencing de dos UPDATE separados (versión de ese momento) afectaba 0 filas
-- al llegar tarde, dejando decision/investigation_status intactos.
--
-- Lo que SÍ se verificó (tercera auditoría, misma fecha): tras agregar las
-- funciones fn_schedule_investigation_attempt, fn_finalize_investigation_
-- attempt, fn_reap_abandoned_attempts y fn_check_rate_limit (y la tabla
-- rate_limit_counters), este archivo se ejecutó de nuevo, completo, contra
-- un contenedor Docker PostgreSQL 16 nuevo y desechable. Primer intento:
-- fn_finalize_investigation_attempt falló con "column reference execution_id
-- is ambiguous" en su RETURNING (colisión entre el nombre de columna de la
-- tabla y el nombre de salida de la función) — se corrigió calificando las
-- columnas (investigation_attempts.execution_id/attempt_number) y se
-- reejecutó con éxito. Con la versión corregida se probó, con datos reales:
-- creación del primer intento sin ventana NOT_STARTED huérfana; un segundo
-- intento de programar mientras PENDING devuelve IN_PROGRESS sin duplicar;
-- un worker sin el claimed_by correcto no puede finalizar el intento de otro
-- (applied=false); el worker correcto finaliza y el resultado se propaga a
-- executions; finalizar el mismo intento una segunda vez no duplica el
-- informe; el reconciliador recupera una ejecución NOT_STARTED simulando un
-- fallo heredado y crea su primer intento sin duplicar; el reaper recupera
-- un intento RUNNING abandonado y dicha recuperación sí se propaga a
-- executions.investigation_status (a diferencia de la versión de dos UPDATE
-- sueltos); y el contador de rate limiting, bajo 20 solicitudes realmente
-- concurrentes (20 procesos psql en paralelo) contra un límite de 10,
-- permitió exactamente 10 y rechazó exactamente 10 — sin evasión por
-- condición de carrera. El detalle completo de esta prueba está en el
-- historial de este repositorio, no en este archivo.
--
-- Corresponde al modelo descrito en docs/database.md (incluida la sección 5,
-- "Concurrencia y recuperación del mecanismo asíncrono de investigación", que
-- agregó claimed_by/claimed_at/latest_attempt_number en la segunda auditoría
-- de esta especificación). Si hay alguna discrepancia, docs/database.md es la
-- fuente de verdad; este archivo debe actualizarse para igualarlo, no al
-- revés.

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid()

-- 1. flow_definitions ---------------------------------------------------

CREATE TABLE flow_definitions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL,
  scenario_id   TEXT NOT NULL,
  version       TEXT NOT NULL,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (scenario_id, version)
);

CREATE INDEX idx_flow_definitions_scenario_active
  ON flow_definitions (scenario_id)
  WHERE is_active;

-- 2. policy_rules ---------------------------------------------------------

CREATE TABLE policy_rules (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id        TEXT NOT NULL,
  policy_version TEXT NOT NULL,
  config_json    JSONB NOT NULL,
  enabled        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (rule_id, policy_version)
);

CREATE INDEX idx_policy_rules_version ON policy_rules (policy_version);

-- 3. budget_balances --------------------------------------------------------

CREATE TABLE budget_balances (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  budget_id        TEXT NOT NULL UNIQUE,
  available_minor  BIGINT NOT NULL CHECK (available_minor >= 0),
  version          INTEGER NOT NULL DEFAULT 1,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 4. payment_requests ---------------------------------------------------

CREATE TABLE payment_requests (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id    TEXT NOT NULL UNIQUE,
  amount_minor  BIGINT NOT NULL CHECK (amount_minor > 0),
  currency      TEXT NOT NULL CHECK (currency IN ('MXN')),
  category      TEXT NOT NULL,
  description   TEXT,
  requester_id  TEXT NOT NULL,
  budget_id     TEXT NOT NULL REFERENCES budget_balances (budget_id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_payment_requests_requester ON payment_requests (requester_id);

-- 5. idempotency_keys -----------------------------------------------------

CREATE TABLE idempotency_keys (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key   TEXT NOT NULL,
  scenario_id       TEXT NOT NULL,
  request_hash      TEXT NOT NULL,
  execution_status  TEXT NOT NULL DEFAULT 'RECEIVED'
                     CHECK (execution_status IN
                       ('RECEIVED','VALIDATING','EVALUATING','PERSISTED','FAILED')),
  execution_id      UUID, -- FK agregada tras crear executions (ver abajo)
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (idempotency_key, scenario_id)
);

-- 6. executions -------------------------------------------------------------

-- Nota: executions NO tiene columna execution_status. Una fila aquí solo existe
-- una vez confirmada la transacción de persistencia, así que su existencia ya
-- implica "PERSISTED"; el ciclo de vida previo (RECEIVED/VALIDATING/EVALUATING/
-- FAILED) vive exclusivamente en idempotency_keys.execution_status. Ver
-- docs/database.md § 1.6 para la justificación completa de este diseño.
CREATE TABLE executions (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  execution_code        TEXT NOT NULL UNIQUE,
  payment_request_id    UUID NOT NULL REFERENCES payment_requests (id),
  engine_version        TEXT NOT NULL,
  policy_version        TEXT NOT NULL,
  decision              TEXT NOT NULL CHECK (decision IN ('ALLOW','BLOCK')),
  investigation_status  TEXT NOT NULL DEFAULT 'NOT_STARTED'
                         CHECK (investigation_status IN
                           ('NOT_STARTED','PENDING','RUNNING','COMPLETED','PARTIAL','FAILED')),
  latest_attempt_number INTEGER NOT NULL DEFAULT 0,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_executions_created_at ON executions (created_at DESC);
CREATE INDEX idx_executions_decision ON executions (decision);
CREATE INDEX idx_executions_investigation_status ON executions (investigation_status);

ALTER TABLE idempotency_keys
  ADD CONSTRAINT fk_idempotency_keys_execution
  FOREIGN KEY (execution_id) REFERENCES executions (id);

-- 7. rule_evaluations ---------------------------------------------------

CREATE TABLE rule_evaluations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  execution_id    UUID NOT NULL REFERENCES executions (id) ON DELETE CASCADE,
  rule_id         TEXT NOT NULL,
  status          TEXT NOT NULL CHECK (status IN ('PASS','FAIL','INDETERMINATE')),
  observed_json   JSONB NOT NULL,
  expected_json   JSONB NOT NULL,
  message         TEXT,
  severity        TEXT NOT NULL DEFAULT 'BLOCKING' CHECK (severity IN ('BLOCKING','INFO')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (execution_id, rule_id)
);

CREATE INDEX idx_rule_evaluations_execution ON rule_evaluations (execution_id);

-- 8. evidence_records ---------------------------------------------------

CREATE TABLE evidence_records (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_ref    TEXT NOT NULL,
  execution_id    UUID NOT NULL REFERENCES executions (id) ON DELETE CASCADE,
  evidence_type   TEXT NOT NULL,
  source          TEXT NOT NULL,
  payload_json    JSONB NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (execution_id, evidence_ref)
);

CREATE INDEX idx_evidence_records_execution ON evidence_records (execution_id);

-- 9. investigation_attempts ------------------------------------------------

CREATE TABLE investigation_attempts (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  attempt_code      TEXT NOT NULL UNIQUE,
  execution_id      UUID NOT NULL REFERENCES executions (id) ON DELETE CASCADE,
  attempt_number    INTEGER NOT NULL,
  status            TEXT NOT NULL CHECK (status IN
                       ('PENDING','RUNNING','COMPLETED','PARTIAL','FAILED')),
  tool_calls_used   INTEGER NOT NULL DEFAULT 0,
  error_code        TEXT,
  claimed_by        TEXT,
  claimed_at        TIMESTAMPTZ,
  started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at      TIMESTAMPTZ,
  UNIQUE (execution_id, attempt_number)
);

CREATE INDEX idx_investigation_attempts_execution ON investigation_attempts (execution_id);

-- Cola de trabajo del worker (ver docs/database.md § 5.2).
CREATE INDEX idx_investigation_attempts_pending
  ON investigation_attempts (started_at)
  WHERE status = 'PENDING';

-- Detección de intentos abandonados por el reaper (ver docs/database.md § 5.3).
CREATE INDEX idx_investigation_attempts_running_claimed
  ON investigation_attempts (claimed_at)
  WHERE status = 'RUNNING';

-- 10. agent_reports ----------------------------------------------------

CREATE TABLE agent_reports (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  attempt_id      UUID NOT NULL REFERENCES investigation_attempts (id) ON DELETE CASCADE,
  provider        TEXT NOT NULL DEFAULT 'nebius',
  model           TEXT NOT NULL,
  prompt_version  TEXT NOT NULL,
  report_json     JSONB NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (attempt_id)
);

-- 11. Row Level Security -----------------------------------------------
--
-- El frontend solo debe leer a través de la API del backend (que usa el rol
-- de servicio), no directamente contra Supabase con la clave `anon`. Por eso
-- el RLS por defecto es restrictivo: niega todo acceso excepto al rol de
-- servicio, que lo evita por definición (bypassrls). Ver docs/security.md § 2.
--
-- Si en algún momento se decide exponer lectura directa desde el navegador
-- con la clave anon (no recomendado para el MVP), se deben agregar políticas
-- SELECT explícitas por tabla en vez de remover este bloqueo general.

ALTER TABLE flow_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE policy_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE budget_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE executions ENABLE ROW LEVEL SECURITY;
ALTER TABLE rule_evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE evidence_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE investigation_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_reports ENABLE ROW LEVEL SECURITY;

-- Sin políticas adicionales: con RLS habilitado y ninguna política definida,
-- el acceso con la clave anon queda denegado por defecto. El rol de servicio
-- (service_role) omite RLS y es el único que el backend debe usar.

-- 12. rate_limit_counters (ver docs/security.md § 2.4) -----------------

CREATE TABLE rate_limit_counters (
  rate_key      TEXT NOT NULL,
  window_start  TIMESTAMPTZ NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (rate_key, window_start)
);

ALTER TABLE rate_limit_counters ENABLE ROW LEVEL SECURITY;

-- 13. Funciones de orquestación atómica ---------------------------------
--
-- Estas funciones existen para que la atomicidad de la programación, la
-- finalización y la recuperación de intentos de investigación viva realmente
-- en PostgreSQL, no en una secuencia de llamadas HTTP ensambladas por el
-- backend. Ver docs/database.md § 5 para la justificación completa de cada
-- una. Se agregaron en la tercera auditoría de esta especificación.

-- 13.1. fn_schedule_investigation_attempt (docs/database.md § 5.1)
-- Usada por: la transacción de creación de la ejecución, POST /investigate,
-- y el reconciliador (§ 5.6). Crea el siguiente intento de forma idempotente
-- y segura ante concurrencia, o informa por qué no se creó.

CREATE OR REPLACE FUNCTION fn_schedule_investigation_attempt(p_execution_id UUID)
RETURNS TABLE(outcome TEXT, attempt_id UUID, attempt_number INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
  v_status TEXT;
  v_latest INTEGER;
  v_attempt_id UUID;
  v_next_attempt INTEGER;
BEGIN
  SELECT investigation_status, latest_attempt_number
  INTO v_status, v_latest
  FROM executions
  WHERE id = p_execution_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'EXECUTION_NOT_FOUND', NULL::UUID, NULL::INTEGER;
    RETURN;
  END IF;

  IF v_status IN ('PENDING', 'RUNNING') THEN
    RETURN QUERY SELECT 'IN_PROGRESS', NULL::UUID, NULL::INTEGER;
    RETURN;
  END IF;

  IF v_status = 'COMPLETED' THEN
    RETURN QUERY SELECT 'ALREADY_COMPLETED', NULL::UUID, NULL::INTEGER;
    RETURN;
  END IF;

  -- v_status aquí solo puede ser NOT_STARTED, FAILED o PARTIAL: los tres son elegibles.
  v_next_attempt := v_latest + 1;

  INSERT INTO investigation_attempts (attempt_code, execution_id, attempt_number, status)
  VALUES ('INV-ATT-' || lpad(v_next_attempt::TEXT, 4, '0') || '-' || substr(p_execution_id::TEXT, 1, 8),
          p_execution_id, v_next_attempt, 'PENDING')
  RETURNING id INTO v_attempt_id;

  UPDATE executions
  SET investigation_status = 'PENDING', latest_attempt_number = v_next_attempt
  WHERE id = p_execution_id;

  RETURN QUERY SELECT 'CREATED', v_attempt_id, v_next_attempt;
END;
$$;

-- 13.2. fn_finalize_investigation_attempt (docs/database.md § 5.4)
-- Usada por: el worker, al terminar de procesar un intento RUNNING (éxito o
-- error de Nebius). Verifica propiedad (claimed_by), verifica vigencia
-- (status = RUNNING), persiste el informe si corresponde, y propaga el
-- resultado a executions solo si el intento sigue siendo el más reciente.

CREATE OR REPLACE FUNCTION fn_finalize_investigation_attempt(
  p_attempt_id      UUID,
  p_claimed_by      TEXT,
  p_final_status    TEXT,
  p_tool_calls_used INTEGER,
  p_error_code      TEXT DEFAULT NULL,
  p_provider        TEXT DEFAULT 'nebius',
  p_model           TEXT DEFAULT NULL,
  p_prompt_version  TEXT DEFAULT NULL,
  p_report_json     JSONB DEFAULT NULL
)
RETURNS TABLE(applied BOOLEAN, propagated BOOLEAN, execution_id UUID, attempt_number INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
  v_execution_id UUID;
  v_attempt_number INTEGER;
  v_rows INTEGER;
BEGIN
  IF p_final_status NOT IN ('COMPLETED', 'PARTIAL', 'FAILED') THEN
    RAISE EXCEPTION 'estado terminal inválido: %', p_final_status;
  END IF;

  UPDATE investigation_attempts
  SET status = p_final_status,
      tool_calls_used = p_tool_calls_used,
      error_code = p_error_code,
      completed_at = now()
  WHERE id = p_attempt_id
    AND status = 'RUNNING'
    AND claimed_by = p_claimed_by
  RETURNING investigation_attempts.execution_id, investigation_attempts.attempt_number
  INTO v_execution_id, v_attempt_number;

  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, FALSE, NULL::UUID, NULL::INTEGER;
    RETURN;
  END IF;

  IF p_final_status IN ('COMPLETED', 'PARTIAL') THEN
    INSERT INTO agent_reports (attempt_id, provider, model, prompt_version, report_json)
    VALUES (p_attempt_id, p_provider, p_model, p_prompt_version, p_report_json);
  END IF;

  UPDATE executions
  SET investigation_status = p_final_status
  WHERE id = v_execution_id AND latest_attempt_number = v_attempt_number;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN QUERY SELECT TRUE, (v_rows > 0), v_execution_id, v_attempt_number;
END;
$$;

-- 13.3. fn_reap_abandoned_attempts (docs/database.md § 5.3)
-- Usada por: el ciclo del reaper, antes de reclamar trabajo nuevo. Recupera
-- intentos RUNNING cuyo claimed_at supera el umbral de abandono, como una
-- sola unidad atómica por fila (marcar el intento Y propagar a executions).

CREATE OR REPLACE FUNCTION fn_reap_abandoned_attempts(p_stale_threshold_ms BIGINT)
RETURNS TABLE(attempt_id UUID, execution_id UUID, attempt_number INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    UPDATE investigation_attempts
    SET status = 'FAILED', error_code = 'WORKER_LOST', completed_at = now()
    WHERE status = 'RUNNING'
      AND claimed_at < now() - (p_stale_threshold_ms || ' milliseconds')::interval
    RETURNING id, investigation_attempts.execution_id, investigation_attempts.attempt_number
  LOOP
    UPDATE executions
    SET investigation_status = 'FAILED'
    WHERE id = r.execution_id
      AND latest_attempt_number = r.attempt_number
      AND investigation_status = 'RUNNING';

    attempt_id := r.id;
    execution_id := r.execution_id;
    attempt_number := r.attempt_number;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- 13.4. fn_check_rate_limit (docs/security.md § 2.4)
-- Contador compartido en PostgreSQL, atómico vía INSERT ... ON CONFLICT ...
-- DO UPDATE: correcto sin importar cuántas instancias del backend lo invocan.

CREATE OR REPLACE FUNCTION fn_check_rate_limit(p_key TEXT, p_window_seconds INT, p_limit INT)
RETURNS TABLE(allowed BOOLEAN, current_count INTEGER, retry_after_seconds INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
  v_window_start TIMESTAMPTZ;
  v_count INTEGER;
BEGIN
  v_window_start := to_timestamp(floor(extract(epoch FROM now()) / p_window_seconds) * p_window_seconds);

  INSERT INTO rate_limit_counters (rate_key, window_start, request_count)
  VALUES (p_key, v_window_start, 1)
  ON CONFLICT (rate_key, window_start)
  DO UPDATE SET request_count = rate_limit_counters.request_count + 1
  RETURNING request_count INTO v_count;

  RETURN QUERY SELECT
    v_count <= p_limit,
    v_count,
    CEIL(EXTRACT(EPOCH FROM (v_window_start + make_interval(secs => p_window_seconds) - now())))::INTEGER;
END;
$$;
