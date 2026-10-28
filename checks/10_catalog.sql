\set ON_ERROR_STOP on
BEGIN;
\ir assertions.sql

SELECT pg_temp.assert_true('PostgreSQL major version 16',
    current_setting('server_version_num')::integer BETWEEN 160000 AND 169999);
SELECT pg_temp.assert_true('raw, core and mart schemas exist',
    (SELECT count(*) = 3 FROM pg_namespace WHERE nspname IN ('raw', 'core', 'mart')));
SELECT pg_temp.assert_true('each required schema contains a table or view',
    (SELECT count(DISTINCT n.nspname) = 3
     FROM pg_namespace n JOIN pg_class c ON c.relnamespace = n.oid
     WHERE n.nspname IN ('raw', 'core', 'mart') AND c.relkind IN ('r', 'p', 'v', 'm')));
SELECT pg_temp.assert_true('core/mart constraints validated', NOT EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname IN ('core', 'mart') AND NOT c.convalidated
));

-- Инвентаризация для привязки к контракту. Наличие constraints не заменяет сверку raw/core.
SELECT n.nspname AS schema_name, t.relname AS relation_name, c.conname,
       c.contype, pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname IN ('core', 'mart')
ORDER BY 1, 2, 3;
ROLLBACK;
\echo 'PASS: catalog checks only; data reconciliation still required'
