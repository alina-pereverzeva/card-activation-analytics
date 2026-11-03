\set ON_ERROR_STOP on
BEGIN;
\ir 01_schema.sql
\ir 02_load.sql
\ir 03_marts.sql
\ir 04_quality_checks.sql
COMMIT;
\ir ../tests/edge_cases.sql
\ir 06_export.sql
