-- Полный payload с _source_file/_loaded_at подтверждён пользователем 2026-10-28.
-- EXCEPT ALL сохраняет кратность: из raw вычитается ровно число отклонённых копий.
\ir assertions.sql
SELECT pg_temp.assert_true('reject source and reason are known and nonempty', NOT EXISTS (
    SELECT 1 FROM core.etl_rejects
    WHERE source_table IS NULL OR source_table NOT IN ('orders', 'customers', 'order_items', 'order_payments',
        'order_reviews', 'products', 'sellers', 'product_category_translation')
       OR nullif(btrim(reason), '') IS NULL OR payload IS NULL OR jsonb_typeof(payload) <> 'object'
));

-- Несколько причин допустимы в одной строке через ';', каждая — из словаря v1.
SELECT pg_temp.assert_true('reject reasons follow v1 dictionary', NOT EXISTS (
    SELECT 1 FROM core.etl_rejects r
    CROSS JOIN LATERAL regexp_split_to_table(r.reason, ';') AS reason(code)
    WHERE code <> 'duplicate_key'
      AND code !~ '^(null_key|bad_type|null_required|invalid_value):[a-z_][a-z0-9_]*$'
      AND code NOT IN ('orphan:customers', 'orphan:orders', 'orphan:products', 'orphan:sellers', 'orphan:categories')
));

DO $$
DECLARE source_name text; bad bigint;
BEGIN
    FOREACH source_name IN ARRAY ARRAY['orders', 'customers', 'order_items', 'order_payments',
        'order_reviews', 'products', 'sellers', 'product_category_translation'] LOOP
        EXECUTE format($query$
            WITH source AS (
                SELECT to_jsonb(r) payload, count(*) n FROM raw.%I r GROUP BY 1
            ), rejected AS (
                SELECT payload, count(*) n FROM core.etl_rejects
                WHERE source_table = $1 GROUP BY payload
            )
            SELECT count(*) FROM rejected j LEFT JOIN source r USING (payload)
            WHERE r.n IS NULL OR j.n > r.n
        $query$, source_name) INTO bad USING source_name;
        IF bad <> 0 THEN
            RAISE EXCEPTION 'reject provenance %: % payload groups absent from raw or over-counted', source_name, bad;
        END IF;
        EXECUTE format($query$
            CREATE TEMP VIEW %I AS
            SELECT * FROM raw.%I
            EXCEPT ALL
            SELECT (jsonb_populate_record(NULL::raw.%I, payload)).*
            FROM core.etl_rejects WHERE source_table = %L
        $query$, 'd_accepted_' || source_name, source_name, source_name, source_name);
    END LOOP;
END;
$$;
