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
-- AVISO (2026-10-17): este archivo se renombró al español según glosario.md
-- de flowguard-docs (tablas, columnas, funciones, parámetros y valores). Las
-- verificaciones que se describen abajo se hicieron con los nombres
-- anteriores en inglés y NO se han repetido tras el renombrado. Queda
-- PENDIENTE DE VERIFICAR al aplicarlo en el proyecto Supabase de desarrollo
-- (Dev 1). Los identificadores citados abajo ya usan los nombres nuevos.
--
-- Lo que SÍ se verificó (segunda auditoría, 2026-10-15): este archivo se
-- ejecutó completo, sin editar, contra un contenedor Docker con PostgreSQL 16
-- genérico (`postgres:16-alpine`) desechado inmediatamente después de la
-- prueba. Se confirmó que: las 32 sentencias se ejecutan en orden sin error;
-- las 10 tablas quedan creadas con RLS habilitado; los índices parciales de
-- intentos_investigacion se crean correctamente; la restricción
-- UNIQUE (clave_idempotencia, escenario_id) rechaza una clave duplicada; y el
-- fencing de dos UPDATE separados (versión de ese momento) afectaba 0 filas
-- al llegar tarde, dejando decision/estado_investigacion intactos.
--
-- Lo que SÍ se verificó (tercera auditoría, misma fecha): tras agregar las
-- funciones fn_programar_intento_investigacion, fn_finalizar_intento_
-- investigacion, fn_recuperar_intentos_abandonados y fn_verificar_limite_solicitudes (y la tabla
-- contadores_limite_solicitudes), este archivo se ejecutó de nuevo, completo, contra
-- un contenedor Docker PostgreSQL 16 nuevo y desechable. Primer intento:
-- fn_finalizar_intento_investigacion falló con "column referencia ejecucion_id
-- is ambiguous" en su RETURNING (colisión entre el nombre de columna de la
-- tabla y el nombre de salida de la función) — se corrigió calificando las
-- columnas (intentos_investigacion.ejecucion_id/numero_intento) y se
-- reejecutó con éxito. Con la versión corregida se probó, con datos reales:
-- creación del primer intento sin ventana NO_INICIADA huérfana; un segundo
-- intento de programar mientras PENDIENTE devuelve EN_PROGRESO sin duplicar;
-- un worker sin el reclamado_por correcto no puede finalizar el intento de otro
-- (aplicado=false); el worker correcto finaliza y el resultado se propaga a
-- ejecuciones; finalizar el mismo intento una segunda vez no duplica el
-- informe; el reconciliador recupera una ejecución NO_INICIADA simulando un
-- fallo heredado y crea su primer intento sin duplicar; el reaper recupera
-- un intento EN_CURSO abandonado y dicha recuperación sí se propaga a
-- ejecuciones.estado_investigacion (a diferencia de la versión de dos UPDATE
-- sueltos); y el contador de rate limiting, bajo 20 solicitudes realmente
-- concurrentes (20 procesos psql en paralelo) contra un límite de 10,
-- permitió exactamente 10 y rechazó exactamente 10 — sin evasión por
-- condición de carrera. El detalle completo de esta prueba está en el
-- historial de este repositorio, no en este archivo.
--
-- Corresponde al modelo descrito en docs/base-datos.md (incluida la sección 5,
-- "Concurrencia y recuperación del mecanismo asíncrono de investigación", que
-- agregó reclamado_por/reclamado_en/numero_ultimo_intento en la segunda auditoría
-- de esta especificación). Si hay alguna discrepancia, docs/base-datos.md es la
-- fuente de verdad; este archivo debe actualizarse para igualarlo, no al
-- revés.

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid()

-- 1. definiciones_flujo ---------------------------------------------------

CREATE TABLE definiciones_flujo (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre          TEXT NOT NULL,
  escenario_id   TEXT NOT NULL,
  version       TEXT NOT NULL,
  activa     BOOLEAN NOT NULL DEFAULT TRUE,
  creado_en    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (escenario_id, version)
);

CREATE INDEX idx_definiciones_flujo_escenario_activa
  ON definiciones_flujo (escenario_id)
  WHERE activa;

-- 2. reglas_politica ---------------------------------------------------------

CREATE TABLE reglas_politica (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  regla_id        TEXT NOT NULL,
  version_politica TEXT NOT NULL,
  configuracion_json    JSONB NOT NULL,
  habilitada        BOOLEAN NOT NULL DEFAULT TRUE,
  creado_en     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (regla_id, version_politica)
);

CREATE INDEX idx_reglas_politica_version ON reglas_politica (version_politica);

-- 3. saldos_presupuesto --------------------------------------------------------

CREATE TABLE saldos_presupuesto (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  presupuesto_id        TEXT NOT NULL UNIQUE,
  disponible_centavos  BIGINT NOT NULL CHECK (disponible_centavos >= 0),
  version          INTEGER NOT NULL DEFAULT 1,
  actualizado_en       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 4. solicitudes_pago ---------------------------------------------------

CREATE TABLE solicitudes_pago (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pago_id    TEXT NOT NULL UNIQUE,
  monto_centavos  BIGINT NOT NULL CHECK (monto_centavos > 0),
  moneda      TEXT NOT NULL CHECK (moneda IN ('MXN')),
  categoria      TEXT NOT NULL,
  descripcion   TEXT,
  solicitante_id  TEXT NOT NULL,
  presupuesto_id     TEXT NOT NULL REFERENCES saldos_presupuesto (presupuesto_id),
  creado_en    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_solicitudes_pago_solicitante ON solicitudes_pago (solicitante_id);

-- 5. claves_idempotencia -----------------------------------------------------

CREATE TABLE claves_idempotencia (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clave_idempotencia   TEXT NOT NULL,
  escenario_id       TEXT NOT NULL,
  hash_solicitud      TEXT NOT NULL,
  estado_ejecucion  TEXT NOT NULL DEFAULT 'RECIBIDA'
                     CHECK (estado_ejecucion IN
                       ('RECIBIDA','VALIDANDO','EVALUANDO','PERSISTIDA','FALLIDA')),
  ejecucion_id      UUID, -- FK agregada tras crear ejecuciones (ver abajo)
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (clave_idempotencia, escenario_id)
);

-- 6. ejecuciones -------------------------------------------------------------

-- Nota: ejecuciones NO tiene columna estado_ejecucion. Una fila aquí solo existe
-- una vez confirmada la transacción de persistencia, así que su existencia ya
-- implica "PERSISTIDA"; el ciclo de vida previo (RECIBIDA/VALIDANDO/EVALUANDO/
-- FALLIDA) vive exclusivamente en claves_idempotencia.estado_ejecucion. Ver
-- docs/base-datos.md § 1.6 para la justificación completa de este diseño.
CREATE TABLE ejecuciones (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo_ejecucion        TEXT NOT NULL UNIQUE,
  solicitud_pago_id    UUID NOT NULL REFERENCES solicitudes_pago (id),
  version_motor        TEXT NOT NULL,
  version_politica        TEXT NOT NULL,
  decision              TEXT NOT NULL CHECK (decision IN ('PERMITIR','BLOQUEAR')),
  estado_investigacion  TEXT NOT NULL DEFAULT 'NO_INICIADA'
                         CHECK (estado_investigacion IN
                           ('NO_INICIADA','PENDIENTE','EN_CURSO','COMPLETADA','PARCIAL','FALLIDA')),
  numero_ultimo_intento INTEGER NOT NULL DEFAULT 0,
  creado_en            TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_en            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_ejecuciones_creado_en ON ejecuciones (creado_en DESC);
CREATE INDEX idx_ejecuciones_decision ON ejecuciones (decision);
CREATE INDEX idx_ejecuciones_estado_investigacion ON ejecuciones (estado_investigacion);

ALTER TABLE claves_idempotencia
  ADD CONSTRAINT fk_claves_idempotencia_ejecucion
  FOREIGN KEY (ejecucion_id) REFERENCES ejecuciones (id);

-- 7. evaluaciones_reglas ---------------------------------------------------

CREATE TABLE evaluaciones_reglas (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ejecucion_id    UUID NOT NULL REFERENCES ejecuciones (id) ON DELETE CASCADE,
  regla_id         TEXT NOT NULL,
  estado          TEXT NOT NULL CHECK (estado IN ('CUMPLE','NO_CUMPLE','INDETERMINADO')),
  observado_json   JSONB NOT NULL,
  esperado_json   JSONB NOT NULL,
  mensaje         TEXT,
  severidad        TEXT NOT NULL DEFAULT 'BLOQUEANTE' CHECK (severidad IN ('BLOQUEANTE','INFORMATIVA')),
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (ejecucion_id, regla_id)
);

CREATE INDEX idx_evaluaciones_reglas_ejecucion ON evaluaciones_reglas (ejecucion_id);

-- 8. registros_evidencia ---------------------------------------------------

CREATE TABLE registros_evidencia (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_evidencia    TEXT NOT NULL,
  ejecucion_id    UUID NOT NULL REFERENCES ejecuciones (id) ON DELETE CASCADE,
  tipo_evidencia   TEXT NOT NULL,
  origen          TEXT NOT NULL,
  contenido_json    JSONB NOT NULL,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (ejecucion_id, ref_evidencia)
);

CREATE INDEX idx_registros_evidencia_ejecucion ON registros_evidencia (ejecucion_id);

-- 9. intentos_investigacion ------------------------------------------------

CREATE TABLE intentos_investigacion (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo_intento      TEXT NOT NULL UNIQUE,
  ejecucion_id      UUID NOT NULL REFERENCES ejecuciones (id) ON DELETE CASCADE,
  numero_intento    INTEGER NOT NULL,
  estado            TEXT NOT NULL CHECK (estado IN
                       ('PENDIENTE','EN_CURSO','COMPLETADA','PARCIAL','FALLIDA')),
  llamadas_herramientas_usadas   INTEGER NOT NULL DEFAULT 0,
  codigo_error        TEXT,
  reclamado_por        TEXT,
  reclamado_en        TIMESTAMPTZ,
  iniciado_en        TIMESTAMPTZ NOT NULL DEFAULT now(),
  completado_en      TIMESTAMPTZ,
  UNIQUE (ejecucion_id, numero_intento)
);

CREATE INDEX idx_intentos_investigacion_ejecucion ON intentos_investigacion (ejecucion_id);

-- Cola de trabajo del worker (ver docs/base-datos.md § 5.2).
CREATE INDEX idx_intentos_investigacion_pendientes
  ON intentos_investigacion (iniciado_en)
  WHERE estado = 'PENDIENTE';

-- Detección de intentos abandonados por el reaper (ver docs/base-datos.md § 5.3).
CREATE INDEX idx_intentos_investigacion_en_curso_reclamados
  ON intentos_investigacion (reclamado_en)
  WHERE estado = 'EN_CURSO';

-- 10. informes_agente ----------------------------------------------------

CREATE TABLE informes_agente (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  intento_id      UUID NOT NULL REFERENCES intentos_investigacion (id) ON DELETE CASCADE,
  proveedor        TEXT NOT NULL DEFAULT 'nebius',
  modelo           TEXT NOT NULL,
  version_prompt  TEXT NOT NULL,
  informe_json     JSONB NOT NULL,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (intento_id)
);

-- 11. Row Level Security -----------------------------------------------
--
-- El frontend solo debe leer a través de la API del backend (que usa el rol
-- de servicio), no directamente contra Supabase con la clave `anon`. Por eso
-- el RLS por defecto es restrictivo: niega todo acceso excepto al rol de
-- servicio, que lo evita por definición (bypassrls). Ver docs/seguridad.md § 2.
--
-- Si en algún momento se decide exponer lectura directa desde el navegador
-- con la clave anon (no recomendado para el MVP), se deben agregar políticas
-- SELECT explícitas por tabla en vez de remover este bloqueo general.

ALTER TABLE definiciones_flujo ENABLE ROW LEVEL SECURITY;
ALTER TABLE reglas_politica ENABLE ROW LEVEL SECURITY;
ALTER TABLE saldos_presupuesto ENABLE ROW LEVEL SECURITY;
ALTER TABLE solicitudes_pago ENABLE ROW LEVEL SECURITY;
ALTER TABLE claves_idempotencia ENABLE ROW LEVEL SECURITY;
ALTER TABLE ejecuciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE evaluaciones_reglas ENABLE ROW LEVEL SECURITY;
ALTER TABLE registros_evidencia ENABLE ROW LEVEL SECURITY;
ALTER TABLE intentos_investigacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE informes_agente ENABLE ROW LEVEL SECURITY;

-- Sin políticas adicionales: con RLS habilitado y ninguna política definida,
-- el acceso con la clave anon queda denegado por defecto. El rol de servicio
-- (service_role) omite RLS y es el único que el backend debe usar.

-- 12. contadores_limite_solicitudes (ver docs/seguridad.md § 2.4) -----------------

CREATE TABLE contadores_limite_solicitudes (
  clave_limite      TEXT NOT NULL,
  inicio_ventana  TIMESTAMPTZ NOT NULL,
  conteo_solicitudes INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (clave_limite, inicio_ventana)
);

ALTER TABLE contadores_limite_solicitudes ENABLE ROW LEVEL SECURITY;

-- 13. Funciones de orquestación atómica ---------------------------------
--
-- Estas funciones existen para que la atomicidad de la programación, la
-- finalización y la recuperación de intentos de investigación viva realmente
-- en PostgreSQL, no en una secuencia de llamadas HTTP ensambladas por el
-- backend. Ver docs/base-datos.md § 5 para la justificación completa de cada
-- una. Se agregaron en la tercera auditoría de esta especificación.

-- 13.1. fn_programar_intento_investigacion (docs/base-datos.md § 5.1)
-- Usada por: la transacción de creación de la ejecución, POST /investigar,
-- y el reconciliador (§ 5.6). Crea el siguiente intento de forma idempotente
-- y segura ante concurrencia, o informa por qué no se creó.

CREATE OR REPLACE FUNCTION fn_programar_intento_investigacion(p_ejecucion_id UUID)
RETURNS TABLE(resultado TEXT, intento_id UUID, numero_intento INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
  v_estado TEXT;
  v_ultimo INTEGER;
  v_intento_id UUID;
  v_siguiente_intento INTEGER;
BEGIN
  SELECT estado_investigacion, numero_ultimo_intento
  INTO v_estado, v_ultimo
  FROM ejecuciones
  WHERE id = p_ejecucion_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'EJECUCION_NO_ENCONTRADA', NULL::UUID, NULL::INTEGER;
    RETURN;
  END IF;

  IF v_estado IN ('PENDIENTE', 'EN_CURSO') THEN
    RETURN QUERY SELECT 'EN_PROGRESO', NULL::UUID, NULL::INTEGER;
    RETURN;
  END IF;

  IF v_estado = 'COMPLETADA' THEN
    RETURN QUERY SELECT 'YA_COMPLETADA', NULL::UUID, NULL::INTEGER;
    RETURN;
  END IF;

  -- v_estado aquí solo puede ser NO_INICIADA, FALLIDA o PARCIAL: los tres son elegibles.
  v_siguiente_intento := v_ultimo + 1;

  INSERT INTO intentos_investigacion (codigo_intento, ejecucion_id, numero_intento, estado)
  VALUES ('INT-' || lpad(v_siguiente_intento::TEXT, 4, '0') || '-' || substr(p_ejecucion_id::TEXT, 1, 8),
          p_ejecucion_id, v_siguiente_intento, 'PENDIENTE')
  RETURNING id INTO v_intento_id;

  UPDATE ejecuciones
  SET estado_investigacion = 'PENDIENTE', numero_ultimo_intento = v_siguiente_intento
  WHERE id = p_ejecucion_id;

  RETURN QUERY SELECT 'CREADO', v_intento_id, v_siguiente_intento;
END;
$$;

-- 13.2. fn_finalizar_intento_investigacion (docs/base-datos.md § 5.4)
-- Usada por: el worker, al terminar de procesar un intento EN_CURSO (éxito o
-- error de Nebius). Verifica propiedad (reclamado_por), verifica vigencia
-- (estado = EN_CURSO), persiste el informe si corresponde, y propaga el
-- resultado a ejecuciones solo si el intento sigue siendo el más reciente.

CREATE OR REPLACE FUNCTION fn_finalizar_intento_investigacion(
  p_intento_id      UUID,
  p_reclamado_por      TEXT,
  p_estado_final    TEXT,
  p_llamadas_herramientas_usadas INTEGER,
  p_codigo_error      TEXT DEFAULT NULL,
  p_proveedor        TEXT DEFAULT 'nebius',
  p_modelo           TEXT DEFAULT NULL,
  p_version_prompt  TEXT DEFAULT NULL,
  p_informe_json     JSONB DEFAULT NULL
)
RETURNS TABLE(aplicado BOOLEAN, propagado BOOLEAN, ejecucion_id UUID, numero_intento INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
  v_ejecucion_id UUID;
  v_numero_intento INTEGER;
  v_filas INTEGER;
BEGIN
  IF p_estado_final NOT IN ('COMPLETADA', 'PARCIAL', 'FALLIDA') THEN
    RAISE EXCEPTION 'estado terminal inválido: %', p_estado_final;
  END IF;

  UPDATE intentos_investigacion
  SET estado = p_estado_final,
      llamadas_herramientas_usadas = p_llamadas_herramientas_usadas,
      codigo_error = p_codigo_error,
      completado_en = now()
  WHERE id = p_intento_id
    AND estado = 'EN_CURSO'
    AND reclamado_por = p_reclamado_por
  RETURNING intentos_investigacion.ejecucion_id, intentos_investigacion.numero_intento
  INTO v_ejecucion_id, v_numero_intento;

  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, FALSE, NULL::UUID, NULL::INTEGER;
    RETURN;
  END IF;

  IF p_estado_final IN ('COMPLETADA', 'PARCIAL') THEN
    INSERT INTO informes_agente (intento_id, proveedor, modelo, version_prompt, informe_json)
    VALUES (p_intento_id, p_proveedor, p_modelo, p_version_prompt, p_informe_json);
  END IF;

  UPDATE ejecuciones
  SET estado_investigacion = p_estado_final
  WHERE id = v_ejecucion_id AND numero_ultimo_intento = v_numero_intento;

  GET DIAGNOSTICS v_filas = ROW_COUNT;

  RETURN QUERY SELECT TRUE, (v_filas > 0), v_ejecucion_id, v_numero_intento;
END;
$$;

-- 13.3. fn_recuperar_intentos_abandonados (docs/base-datos.md § 5.3)
-- Usada por: el ciclo del reaper, antes de reclamar trabajo nuevo. Recupera
-- intentos EN_CURSO cuyo reclamado_en supera el umbral de abandono, como una
-- sola unidad atómica por fila (marcar el intento Y propagar a ejecuciones).

CREATE OR REPLACE FUNCTION fn_recuperar_intentos_abandonados(p_umbral_abandono_ms BIGINT)
RETURNS TABLE(intento_id UUID, ejecucion_id UUID, numero_intento INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    UPDATE intentos_investigacion
    SET estado = 'FALLIDA', codigo_error = 'PROCESO_PERDIDO', completado_en = now()
    WHERE estado = 'EN_CURSO'
      AND reclamado_en < now() - (p_umbral_abandono_ms || ' milliseconds')::interval
    RETURNING id, intentos_investigacion.ejecucion_id, intentos_investigacion.numero_intento
  LOOP
    UPDATE ejecuciones
    SET estado_investigacion = 'FALLIDA'
    WHERE id = r.ejecucion_id
      AND numero_ultimo_intento = r.numero_intento
      AND estado_investigacion = 'EN_CURSO';

    intento_id := r.id;
    ejecucion_id := r.ejecucion_id;
    numero_intento := r.numero_intento;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- 13.4. fn_verificar_limite_solicitudes (docs/seguridad.md § 2.4)
-- Contador compartido en PostgreSQL, atómico vía INSERT ... ON CONFLICT ...
-- DO UPDATE: correcto sin importar cuántas instancias del backend lo invocan.

CREATE OR REPLACE FUNCTION fn_verificar_limite_solicitudes(p_clave TEXT, p_ventana_segundos INT, p_limite INT)
RETURNS TABLE(permitido BOOLEAN, conteo_actual INTEGER, reintentar_tras_segundos INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
  v_inicio_ventana TIMESTAMPTZ;
  v_conteo INTEGER;
BEGIN
  v_inicio_ventana := to_timestamp(floor(extract(epoch FROM now()) / p_ventana_segundos) * p_ventana_segundos);

  INSERT INTO contadores_limite_solicitudes (clave_limite, inicio_ventana, conteo_solicitudes)
  VALUES (p_clave, v_inicio_ventana, 1)
  ON CONFLICT (clave_limite, inicio_ventana)
  DO UPDATE SET conteo_solicitudes = contadores_limite_solicitudes.conteo_solicitudes + 1
  RETURNING conteo_solicitudes INTO v_conteo;

  RETURN QUERY SELECT
    v_conteo <= p_limite,
    v_conteo,
    CEIL(EXTRACT(EPOCH FROM (v_inicio_ventana + make_interval(secs => p_ventana_segundos) - now())))::INTEGER;
END;
$$;
