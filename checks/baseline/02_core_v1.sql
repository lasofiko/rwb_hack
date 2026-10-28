\set ON_ERROR_STOP on
\ir ../lib/assertions.sql
-- Ожидания фиксированного снимка из docs/contract.md v1, не будущих загрузок.
-- Запускать отдельно вместе с 01_raw_baseline.sql; runner не включает baseline.
DO $$
DECLARE spec record; actual bigint;
BEGIN
    FOR spec IN SELECT * FROM (VALUES
        ('customers', 96096), ('orders', 99441), ('order_items', 112650),
        ('order_payments', 103886), ('order_reviews', 99224), ('products', 32951),
        ('sellers', 3095), ('categories', 73), ('calendar', 821), ('etl_rejects', 0)
    ) AS expected(table_name, row_count) LOOP
        EXECUTE format('SELECT count(*) FROM core.%I', spec.table_name) INTO actual;
        PERFORM pg_temp.assert_numeric('v1 fixed snapshot count: ' || spec.table_name, actual, spec.row_count);
    END LOOP;
END;
$$;
SELECT pg_temp.assert_numeric('v1 price', (SELECT sum(price) FROM core.order_items), 13591643.70);
SELECT pg_temp.assert_numeric('v1 freight', (SELECT sum(freight_value) FROM core.order_items), 2256599.44);
SELECT pg_temp.assert_numeric('v1 payments', (SELECT sum(payment_value) FROM core.order_payments), 16008872.12);
SELECT pg_temp.assert_numeric('v1 products NULL category',
    (SELECT count(*)::numeric FROM core.products WHERE product_category_name IS NULL), 610);
SELECT pg_temp.assert_numeric('v1 untranslated categories',
    (SELECT count(*)::numeric FROM core.categories WHERE product_category_name_english IS NULL), 2);
SELECT pg_temp.assert_true('v1 calendar bounds',
    (SELECT min(day) = date '2016-09-01' AND max(day) = date '2018-11-30'
        AND count(DISTINCT month_start) = 27 FROM core.calendar));
