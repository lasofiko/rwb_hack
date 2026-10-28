\set ON_ERROR_STOP on
-- Сравнение повторных сборок, не доказательство правильности формул.
-- Транзакцией управляет вызывающий psql; использовать REPEATABLE READ (см. README).
CREATE TEMP TABLE d_snapshot_exclusions (
    schema_name text, relation_name text, column_names text[] NOT NULL,
    PRIMARY KEY (schema_name, relation_name), CHECK (schema_name IN ('core', 'mart'))
) ON COMMIT DROP;
-- После контракта D явно добавляет ТОЛЬКО технические timestamps.
-- До этого сравниваются все колонки; хронология заказов никогда не исключается.

CREATE FUNCTION pg_temp.d_fingerprint(schema_name text, relation_name text, excluded text[])
RETURNS TABLE (row_count bigint, fingerprint text) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE format(
        'SELECT count(*), md5(coalesce(string_agg(h, '''' ORDER BY h), ''''))
         FROM (SELECT md5((to_jsonb(t) - $1)::text) AS h FROM %I.%I t) row_hashes',
        schema_name, relation_name) USING excluded;
END;
$$;

SELECT n.nspname AS schema_name, c.relname AS relation_name,
       coalesce(e.column_names, ARRAY[]::text[]) AS excluded_columns,
       f.row_count, f.fingerprint
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN d_snapshot_exclusions e ON e.schema_name = n.nspname AND e.relation_name = c.relname
CROSS JOIN LATERAL pg_temp.d_fingerprint(
    n.nspname::text, c.relname::text, coalesce(e.column_names, ARRAY[]::text[])) f
WHERE n.nspname IN ('raw', 'core', 'mart') AND c.relkind IN ('r', 'p', 'v', 'm')
  AND NOT c.relispartition
ORDER BY 1, 2;
