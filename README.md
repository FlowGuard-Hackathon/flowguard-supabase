# flowguard-supabase

Migración SQL de referencia del esquema de PostgreSQL/Supabase de FlowGuard: 11 tablas, RLS habilitado, y 4 funciones PL/pgSQL para el mecanismo asíncrono de investigación y el *rate limiting*.

**Responsable principal:** Dev 1 (backend, persistencia).

## Contenido

- [`migrations/001_initial_schema.sql`](migrations/001_initial_schema.sql) — esquema inicial completo.

Corresponde exactamente al modelo descrito en [flowguard-docs/database.md](https://github.com/FlowGuard-Hackathon/flowguard-docs/blob/main/database.md) — ese documento es la fuente de verdad; este SQL debe actualizarse para igualarlo si hay alguna discrepancia, nunca al revés.

## Estado de verificación

Esta migración se ejecutó y se probó con datos reales (incluida una prueba de concurrencia real) contra un PostgreSQL 16 genérico en un contenedor Docker desechable — **no** contra un proyecto Supabase real. Ver el comentario de cabecera de [`migrations/001_initial_schema.sql`](migrations/001_initial_schema.sql) y la nota de verificación en [flowguard-docs/database.md](https://github.com/FlowGuard-Hackathon/flowguard-docs/blob/main/database.md) para el detalle exacto de qué se probó.

## Cómo usarla

El repositorio que efectivamente despliega la aplicación (`flowguard-app`/`flowguard-src`, o el `flowguard` combinado) debe:

1. Copiar `migrations/001_initial_schema.sql` a su propia carpeta `supabase/migrations/`.
2. Aplicarla con `supabase db push` (o el mecanismo de migraciones que el equipo adopte) contra un proyecto Supabase real.
3. Confirmar ahí mismo el comportamiento de los roles `anon`/`service_role` y la invocación de las funciones vía `supabase.rpc(...)`, que no se ha verificado todavía (ver riesgo abierto en [flowguard-docs/implementation-checklist.md](https://github.com/FlowGuard-Hackathon/flowguard-docs/blob/main/implementation-checklist.md)).
