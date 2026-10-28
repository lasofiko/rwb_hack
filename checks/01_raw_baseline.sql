\set ON_ERROR_STOP on
-- Приёмка фиксированной исходной поставки, НЕ универсальный инвариант модели.
-- DDL: PR #2, commit 9303929a0ba45c24118dc9f026470c325a6b3e68.
-- Объёмы: docs/handout.md раздатки 3da32d149bfa14dca3fdb0c5863d0771c38efbfc.
-- Не профилирует ключи/NULL/сирот: это работа B. Объекты raw не изменяются.
BEGIN ISOLATION LEVEL REPEATABLE READ;
\ir assertions.sql

CREATE TEMP TABLE d_raw_expected (
    table_name text PRIMARY KEY, expected_rows bigint NOT NULL,
    source_file text NOT NULL, business_columns text[] NOT NULL
) ON COMMIT DROP;
INSERT INTO d_raw_expected VALUES
('orders', 99441, 'olist_orders_dataset.csv', ARRAY[
    'order_id', 'customer_id', 'order_status', 'order_purchase_timestamp',
    'order_approved_at', 'order_delivered_carrier_date',
    'order_delivered_customer_date', 'order_estimated_delivery_date']),
('order_items', 112650, 'olist_order_items_dataset.csv', ARRAY[
    'order_id', 'order_item_id', 'product_id', 'seller_id', 'shipping_limit_date',
    'price', 'freight_value']),
('order_payments', 103886, 'olist_order_payments_dataset.csv', ARRAY[
    'order_id', 'payment_sequential', 'payment_type', 'payment_installments', 'payment_value']),
('order_reviews', 99224, 'olist_order_reviews_dataset.csv', ARRAY[
    'review_id', 'order_id', 'review_score', 'review_comment_title',
    'review_comment_message', 'review_creation_date', 'review_answer_timestamp']),
('products', 32951, 'olist_products_dataset.csv', ARRAY[
    'product_id', 'product_category_name', 'product_name_lenght',
    'product_description_lenght', 'product_photos_qty', 'product_weight_g',
    'product_length_cm', 'product_height_cm', 'product_width_cm']),
('sellers', 3095, 'olist_sellers_dataset.csv', ARRAY[
    'seller_id', 'seller_zip_code_prefix', 'seller_city', 'seller_state']),
('customers', 99441, 'olist_customers_dataset.csv', ARRAY[
    'customer_id', 'customer_unique_id', 'customer_zip_code_prefix', 'customer_city', 'customer_state']),
('product_category_translation', 71, 'product_category_name_translation.csv', ARRAY[
    'product_category_name', 'product_category_name_english']);

CREATE TEMP TABLE d_raw_observed (
    table_name text PRIMARY KEY, row_count bigint NOT NULL,
    invalid_source_rows bigint NOT NULL, missing_load_time_rows bigint NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
    spec record;
    relation_oid oid;
    actual_columns text[];
    expected_columns text[];
    invalid_types bigint;
    actual_rows bigint;
    bad_source bigint;
    missing_load_time bigint;
BEGIN
    FOR spec IN SELECT * FROM d_raw_expected ORDER BY table_name LOOP
        SELECT c.oid INTO relation_oid
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'raw' AND c.relname = spec.table_name AND c.relkind IN ('r', 'p');
        PERFORM pg_temp.assert_true('raw table exists: ' || spec.table_name, relation_oid IS NOT NULL);

        SELECT array_agg(a.attname::text ORDER BY a.attname::text) INTO actual_columns
        FROM pg_attribute a WHERE a.attrelid = relation_oid AND a.attnum > 0 AND NOT a.attisdropped;
        SELECT array_agg(x ORDER BY x) INTO expected_columns
        FROM unnest(spec.business_columns || ARRAY['_source_file', '_loaded_at']) AS u(x);
        PERFORM pg_temp.assert_true('raw columns match DDL: ' || spec.table_name,
            actual_columns = expected_columns);

        SELECT count(*) INTO invalid_types FROM pg_attribute a
        WHERE a.attrelid = relation_oid AND a.attnum > 0 AND NOT a.attisdropped
          AND a.atttypid <> CASE WHEN a.attname = '_loaded_at'
              THEN 'timestamp with time zone'::regtype ELSE 'text'::regtype END;
        PERFORM pg_temp.assert_numeric('raw column types: ' || spec.table_name, invalid_types, 0);

        EXECUTE format(
            'SELECT count(*), count(*) FILTER (WHERE _source_file IS DISTINCT FROM $1),
                    count(*) FILTER (WHERE _loaded_at IS NULL) FROM raw.%I', spec.table_name)
        INTO actual_rows, bad_source, missing_load_time USING spec.source_file;
        PERFORM pg_temp.assert_numeric('fixed delivery row count: ' || spec.table_name,
            actual_rows, spec.expected_rows);
        PERFORM pg_temp.assert_numeric('source filename: ' || spec.table_name, bad_source, 0);
        PERFORM pg_temp.assert_numeric('load timestamp exists: ' || spec.table_name, missing_load_time, 0);
        INSERT INTO d_raw_observed VALUES (spec.table_name, actual_rows, bad_source, missing_load_time);
    END LOOP;
END;
$$;

SELECT pg_temp.assert_numeric('fixed delivery total rows',
    (SELECT sum(row_count) FROM d_raw_observed), 550759);
SELECT * FROM d_raw_observed ORDER BY table_name;
ROLLBACK;
\echo 'PASS: fixed raw delivery only; core/mart correctness not tested'
