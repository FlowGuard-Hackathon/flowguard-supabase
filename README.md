# flowguard-supabase

Migración SQL de referencia del esquema de PostgreSQL/Supabase de FlowGuard: 11 tablas, RLS habilitado, y 4 funciones PL/pgSQL para el mecanismo asíncrono de investigación y el *rate limiting*.

**Responsable principal:** Dev 1 (backend, persistencia).

## Contenido

- [`migrations/001_esquema_inicial.sql`](migrations/001_esquema_inicial.sql) — esquema inicial completo.

Corresponde exactamente al modelo descrito en [flowguard-docs/base-datos.md](https://github.com/FlowGuard-Hackathon/flowguard-docs/blob/main/base-datos.md) — ese documento es la fuente de verdad; este SQL debe actualizarse para igualarlo si hay alguna discrepancia, nunca al revés.

## Estado de verificación

**Pendiente de verificar.** El 2026-10-17 la migración se renombró al español según el [glosario](https://github.com/FlowGuard-Hackathon/flowguard-docs/blob/main/glosario.md) (tablas, columnas, funciones, parámetros y valores) y **no se ha vuelto a ejecutar** desde entonces. Se verificará al aplicarla en el proyecto Supabase de desarrollo (Dev 1, paso 4 de abajo).

Antes del renombrado, la versión con nombres en inglés se ejecutó y se probó con datos reales (incluida una prueba de concurrencia real) contra un PostgreSQL 16 genérico, **no** contra un proyecto Supabase real. Esa evidencia ya no aplica tal cual a esta versión. Ver el comentario de cabecera de [`migrations/001_esquema_inicial.sql`](migrations/001_esquema_inicial.sql) y la nota de verificación en [flowguard-docs/base-datos.md](https://github.com/FlowGuard-Hackathon/flowguard-docs/blob/main/base-datos.md) para el detalle exacto de qué se probó.

## Cómo usarla

El repositorio que efectivamente despliega la aplicación (`flowguard-app`/`flowguard-src`, o el `flowguard` combinado) debe:

1. Copiar `migrations/001_esquema_inicial.sql` a su propia carpeta `supabase/migrations/`.
2. Aplicarla con `supabase db push` (o el mecanismo de migraciones que el equipo adopte) contra un proyecto Supabase real.
3. Confirmar ahí mismo el comportamiento de los roles `anon`/`service_role` y la invocación de las funciones vía `supabase.rpc(...)`, que no se ha verificado todavía (ver riesgo abierto en [flowguard-docs/checklist-implementacion.md](https://github.com/FlowGuard-Hackathon/flowguard-docs/blob/main/checklist-implementacion.md)).
4. Repetir en ese proyecto las comprobaciones de la cabecera del archivo (crear el primer intento, programar dos veces, finalizar con otro `reclamado_por`, *reaper*, límite de solicitudes) y anotar el resultado en [flowguard-docs/pruebas.md](https://github.com/FlowGuard-Hackathon/flowguard-docs/blob/main/pruebas.md). Hasta entonces, esta migración se considera **no verificada**.
