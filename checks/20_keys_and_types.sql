\set ON_ERROR_STOP on
\ir lib/assertions.sql

-- Контракт v1. etl_rejects намеренно не имеет PK.
DO $$
DECLARE spec record; bad bigint; keys_sql text; null_sql text;
BEGIN
    FOR spec IN SELECT * FROM (VALUES
        ('customers', ARRAY['customer_unique_id']),
        ('orders', ARRAY['order_id']), ('orders', ARRAY['customer_id']),
        ('order_items', ARRAY['order_id', 'order_item_id']),
        ('order_payments', ARRAY['order_id', 'payment_sequential']),
        ('order_reviews', ARRAY['review_id', 'order_id']),
        ('products', ARRAY['product_id']), ('sellers', ARRAY['seller_id']),
        ('categories', ARRAY['product_category_name']), ('calendar', ARRAY['day'])
    ) AS expected(table_name, key_columns) LOOP
        SELECT string_agg(format('%I', k), ', '), string_agg(format('%I IS NULL', k), ' OR ')
        INTO keys_sql, null_sql FROM unnest(spec.key_columns) AS u(k);
        EXECUTE format('SELECT count(*) FROM core.%I WHERE %s', spec.table_name, null_sql) INTO bad;
        PERFORM pg_temp.assert_numeric('key NULL: ' || spec.table_name || '(' || keys_sql || ')', bad, 0);
        EXECUTE format('SELECT count(*) FROM (SELECT %s FROM core.%I GROUP BY %s HAVING count(*) > 1) d',
            keys_sql, spec.table_name, keys_sql) INTO bad;
        PERFORM pg_temp.assert_numeric('key duplicate: ' || spec.table_name || '(' || keys_sql || ')', bad, 0);
    END LOOP;

    FOR spec IN SELECT * FROM (VALUES
        ('orders', 'customer_unique_id', 'customers', 'customer_unique_id'),
        ('order_items', 'order_id', 'orders', 'order_id'),
        ('order_items', 'product_id', 'products', 'product_id'),
        ('order_items', 'seller_id', 'sellers', 'seller_id'),
        ('order_payments', 'order_id', 'orders', 'order_id'),
        ('order_reviews', 'order_id', 'orders', 'order_id'),
        ('products', 'product_category_name', 'categories', 'product_category_name')
    ) AS expected(child_table, child_column, parent_table, parent_column) LOOP
        EXECUTE format('SELECT count(*) FROM core.%I c WHERE c.%I IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM core.%I p WHERE p.%I = c.%I)',
            spec.child_table, spec.child_column, spec.parent_table, spec.parent_column, spec.child_column) INTO bad;
        PERFORM pg_temp.assert_numeric('FK: ' || spec.child_table || '.' || spec.child_column, bad, 0);
    END LOOP;
END;
$$;

SELECT pg_temp.assert_true('payment installments preserve zero but reject negative values', NOT EXISTS (
    SELECT 1 FROM core.order_payments WHERE payment_installments < 0
));

-- Проверять типы явно: изменения DDL не должны молча ограничить scale или добавить timezone.
DO $$
DECLARE spec record; correct boolean;
BEGIN
    FOR spec IN SELECT * FROM (VALUES
        ('order_items', 'price', 'numeric'), ('order_items', 'freight_value', 'numeric'),
        ('order_payments', 'payment_value', 'numeric'),
        ('orders', 'order_purchase_timestamp', 'timestamp without time zone'),
        ('orders', 'order_approved_at', 'timestamp without time zone'),
        ('orders', 'order_delivered_carrier_date', 'timestamp without time zone'),
        ('orders', 'order_delivered_customer_date', 'timestamp without time zone'),
        ('orders', 'order_estimated_delivery_date', 'date'),
        ('order_items', 'shipping_limit_date', 'timestamp without time zone'),
        ('order_reviews', 'review_creation_date', 'timestamp without time zone'),
        ('order_reviews', 'review_answer_timestamp', 'timestamp without time zone'),
        ('orders', 'customer_zip_code_prefix', 'text'), ('sellers', 'seller_zip_code_prefix', 'text')
    ) AS expected(table_name, column_name, type_name) LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'core' AND c.relname = spec.table_name AND a.attname = spec.column_name
              AND a.attnum > 0 AND NOT a.attisdropped
              AND a.atttypid = spec.type_name::regtype AND a.atttypmod = -1
        ) INTO correct;
        PERFORM pg_temp.assert_true('type: ' || spec.table_name || '.' || spec.column_name, correct);
    END LOOP;
END;
$$;
