-- Только отдельная тестовая БД, никаких вставок в штатный raw команды.
-- Транзакция создаётся smoke_checks.py и целиком откатывается.
DO $$
BEGIN
    IF current_database() <> 'd_checks_fixture' THEN
        RAISE EXCEPTION 'fixture requires dedicated d_checks_fixture database';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('raw', 'core', 'mart')) THEN
        RAISE EXCEPTION 'fixture requires an empty database';
    END IF;
END;
$$;
CREATE SCHEMA raw;
CREATE SCHEMA core;
CREATE SCHEMA mart;
\ir ../../scripts/init/02_raw_ddl.sql
\ir ../../model/10_ddl.sql

INSERT INTO raw.customers (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state) VALUES
    ('c1', 'u1', '0123', '  city one  ', 'SP'),
    ('c2', 'u1', '12345', 'city two', 'RJ'), ('c3', 'u2', '4567', NULL, 'SP');
INSERT INTO raw.orders (order_id, customer_id, order_status, order_purchase_timestamp, order_estimated_delivery_date) VALUES
    ('o1', 'c1', 'delivered', '2016-09-10 12:00:00', '2016-10-01 00:00:00'),
    ('o2', 'c2', 'delivered', '2016-11-01 12:00:00', '2016-12-22 00:00:00'),
    ('o3', 'c3', 'canceled', '2016-11-10 12:00:00', NULL);
INSERT INTO raw.sellers (seller_id, seller_zip_code_prefix, seller_city, seller_state) VALUES
    ('s1', '0123', '  seller city  ', 'SP'), ('s2', '12345', NULL, 'RJ');
INSERT INTO raw.product_category_translation (product_category_name, product_category_name_english) VALUES ('known', 'known_en');
INSERT INTO raw.products (product_id, product_category_name, product_photos_qty) VALUES
    ('p1', 'known', '1'), ('p2', NULL, ''), ('p3', 'untranslated', NULL);
INSERT INTO raw.order_items (order_id, order_item_id, product_id, seller_id, price, freight_value) VALUES
    ('o1', '1', 'p1', 's1', '10.105', '1.00'), ('o1', '2', 'p2', 's2', '20.20', '2.00'),
    ('o2', '1', 'p3', 's1', '5.05', '0');
INSERT INTO raw.order_payments (order_id, payment_sequential, payment_type, payment_installments, payment_value) VALUES
    ('o1', '1', 'credit_card', '0', '15.00'), ('o1', '2', 'voucher', '1', '18.305'),
    ('o2', '1', 'not_defined', NULL, '5.05'), ('o2', '2', 'voucher', '1', '0');
INSERT INTO raw.order_reviews (review_id, order_id, review_score, review_comment_title, review_comment_message) VALUES
    ('r1', 'o1', '4', '  title  ', '   '), ('r2', 'o1', '5', NULL, '  message  '),
    ('r1', 'o2', '3', '', NULL);

-- Только построение тестового примера; это не ETL B и не приёмка реальных данных.
INSERT INTO core.customers VALUES ('u1'), ('u2');
INSERT INTO core.categories VALUES ('known', 'known_en'), ('untranslated', NULL);
INSERT INTO core.sellers SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state FROM raw.sellers;
INSERT INTO core.products (product_id, product_category_name, product_photos_qty)
SELECT product_id, product_category_name, nullif(product_photos_qty, '')::integer FROM raw.products;
INSERT INTO core.orders (order_id, customer_id, customer_unique_id, order_status, order_purchase_timestamp,
    order_estimated_delivery_date, customer_zip_code_prefix, customer_city, customer_state)
SELECT o.order_id, o.customer_id, c.customer_unique_id, o.order_status, o.order_purchase_timestamp::timestamp,
    o.order_estimated_delivery_date::date, c.customer_zip_code_prefix, c.customer_city, c.customer_state
FROM raw.orders o JOIN raw.customers c USING (customer_id);
INSERT INTO core.order_items (order_id, order_item_id, product_id, seller_id, price, freight_value)
SELECT order_id, order_item_id::integer, product_id, seller_id, price::numeric, freight_value::numeric FROM raw.order_items;
INSERT INTO core.order_payments (order_id, payment_sequential, payment_type, payment_installments, payment_value)
SELECT order_id, payment_sequential::integer, payment_type, payment_installments::integer, payment_value::numeric FROM raw.order_payments;
INSERT INTO core.order_reviews (review_id, order_id, review_score, review_comment_title, review_comment_message)
SELECT review_id, order_id, review_score::smallint, review_comment_title, review_comment_message FROM raw.order_reviews;
INSERT INTO core.calendar (day, month_start, year, iso_dow)
SELECT d::date, date_trunc('month', d)::date, extract(year FROM d)::smallint, extract(isodow FROM d)::smallint
FROM generate_series(timestamp '2016-09-01', timestamp '2016-12-31', interval '1 day') AS days(d);
