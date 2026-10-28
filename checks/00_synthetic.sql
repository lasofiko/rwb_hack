\set ON_ERROR_STOP on
BEGIN;
\ir assertions.sql

-- Фикстуры изолированы от raw/core/mart и откатываются целиком.
CREATE TEMP TABLE d_orders (
    order_id text PRIMARY KEY, customer_id text NOT NULL,
    customer_unique_id text NOT NULL, purchased_at timestamp NOT NULL,
    state text NOT NULL
) ON COMMIT DROP;
INSERT INTO d_orders VALUES
    ('o1', 'c1', 'u1', '2017-01-10 10:00:00', 'SP'),
    ('o2', 'c2', 'u1', '2017-03-10 10:00:00', 'RJ'),
    ('o3', 'c3', 'u2', '2017-03-11 10:00:00', 'SP');

CREATE TEMP TABLE d_items (
    order_id text REFERENCES d_orders, order_item_id integer,
    seller_id text NOT NULL, category text, price numeric,
    freight numeric NOT NULL, PRIMARY KEY (order_id, order_item_id)
) ON COMMIT DROP;
INSERT INTO d_items VALUES
    ('o1', 1, 's1', 'known', 10.10, 1.00),
    ('o1', 2, 's2', NULL, 20.20, 2.00),
    ('o2', 1, 's1', 'untranslated', 5.05, 0.00),
    ('o3', 1, 's2', 'known', NULL, 0.00);

CREATE TEMP TABLE d_payments (
    order_id text REFERENCES d_orders, payment_sequential integer,
    amount numeric NOT NULL, PRIMARY KEY (order_id, payment_sequential)
) ON COMMIT DROP;
INSERT INTO d_payments VALUES
    ('o1', 1, 15.00), ('o1', 2, 18.30), ('o2', 1, 5.05);

-- review_id намеренно повторяется; один заказ имеет несколько отзывов.
CREATE TEMP TABLE d_reviews (
    source_row integer PRIMARY KEY, review_id text NOT NULL,
    order_id text REFERENCES d_orders, score integer NOT NULL
) ON COMMIT DROP;
INSERT INTO d_reviews VALUES
    (1, 'r1', 'o1', 4), (2, 'r2', 'o1', 5), (3, 'r1', 'o2', 3);

-- Прямой JOIN умножает 30.30 первого заказа на 2 платежа × 2 отзыва.
SELECT pg_temp.assert_numeric('fixture exposes fanout',
    (SELECT sum(i.price) FROM d_items i
     JOIN d_payments p USING (order_id) JOIN d_reviews r USING (order_id)), 126.25);

CREATE TEMP TABLE d_order_fact ON COMMIT DROP AS
WITH items AS (
    SELECT order_id, sum(price) revenue, count(*) item_count,
           count(*) FILTER (WHERE price IS NULL) missing_price_count
    FROM d_items GROUP BY order_id
), payments AS (
    SELECT order_id, sum(amount) payment_total, count(*) payment_count
    FROM d_payments GROUP BY order_id
), reviews AS (
    SELECT order_id, count(*) review_count FROM d_reviews GROUP BY order_id
)
SELECT o.*, i.revenue, i.item_count, i.missing_price_count,
       p.payment_total, coalesce(p.payment_count, 0) payment_count,
       coalesce(r.review_count, 0) review_count
FROM d_orders o LEFT JOIN items i USING (order_id)
LEFT JOIN payments p USING (order_id) LEFT JOIN reviews r USING (order_id);

SELECT pg_temp.assert_numeric('one row per order',
    (SELECT count(*)::numeric FROM d_order_fact), 3);
SELECT pg_temp.assert_numeric('item amount survives joins',
    (SELECT sum(revenue) FROM d_order_fact), (SELECT sum(price) FROM d_items));
SELECT pg_temp.assert_numeric('payments survive joins',
    (SELECT sum(payment_total) FROM d_order_fact), (SELECT sum(amount) FROM d_payments));
SELECT pg_temp.assert_true('multiple payments and reviews retained',
    (SELECT payment_count = 2 AND review_count = 2 FROM d_order_fact WHERE order_id = 'o1'));
SELECT pg_temp.assert_true('missing payment and price remain NULL',
    (SELECT payment_total IS NULL AND revenue IS NULL AND missing_price_count = 1
     FROM d_order_fact WHERE order_id = 'o3'));
SELECT pg_temp.assert_numeric('repeated review id retained',
    (SELECT count(*)::numeric FROM d_reviews WHERE review_id = 'r1'), 2);

SELECT pg_temp.assert_numeric('seller owns only own item prices',
    (SELECT sum(price) FROM d_items WHERE seller_id = 's1'), 15.15);

-- Неизвестная категория и отсутствие перевода не должны удалять позиции.
CREATE TEMP TABLE d_translations (category text PRIMARY KEY, english text) ON COMMIT DROP;
INSERT INTO d_translations VALUES ('known', 'known_en');
CREATE TEMP TABLE d_categories ON COMMIT DROP AS
SELECT i.*, t.english,
       CASE WHEN i.category IS NULL THEN 'missing_category'
            WHEN t.english IS NULL THEN 'missing_translation' ELSE 'known' END category_status
FROM d_items i LEFT JOIN d_translations t USING (category);
SELECT pg_temp.assert_numeric('category join retains rows',
    (SELECT count(*)::numeric FROM d_categories), 4);
SELECT pg_temp.assert_numeric('category join retains amount',
    (SELECT sum(price) FROM d_categories), 35.35);
SELECT pg_temp.assert_numeric('unknown category retained',
    (SELECT count(*)::numeric FROM d_categories WHERE category_status = 'missing_category'), 1);
SELECT pg_temp.assert_numeric('missing translation retained separately',
    (SELECT count(*)::numeric FROM d_categories WHERE category_status = 'missing_translation'), 1);

CREATE TEMP TABLE d_months ON COMMIT DROP AS
WITH axis AS (
    SELECT generate_series(timestamp '2017-01-01', timestamp '2017-03-01', interval '1 month') month
), facts AS (
    SELECT date_trunc('month', purchased_at) month, count(*) order_count
    FROM d_orders GROUP BY 1
)
SELECT a.month, coalesce(f.order_count, 0) order_count
FROM axis a LEFT JOIN facts f USING (month);
SELECT pg_temp.assert_numeric('calendar retains all months',
    (SELECT count(*)::numeric FROM d_months), 3);
SELECT pg_temp.assert_numeric('empty February retained',
    (SELECT order_count::numeric FROM d_months WHERE month = timestamp '2017-02-01'), 0);

SELECT pg_temp.assert_numeric('unique customers use stable id',
    (SELECT count(DISTINCT customer_unique_id)::numeric FROM d_orders), 2);
SELECT pg_temp.assert_numeric('repeat rate denominator is customers',
    (SELECT 100.0 * count(*) FILTER (WHERE n > 1) / count(*)
     FROM (SELECT customer_unique_id, count(*) n FROM d_orders GROUP BY 1) x), 50);
SELECT pg_temp.assert_true('order address preserved when customer moves',
    (SELECT count(DISTINCT state) = 2 FROM d_orders WHERE customer_unique_id = 'u1'));
SELECT pg_temp.assert_numeric('distinct customers are not additive by state',
    (SELECT sum(n) FROM (SELECT state, count(DISTINCT customer_unique_id) n
                        FROM d_orders GROUP BY state) x), 3);

-- Проверка самого assert: FALSE и NULL обязаны вызывать исключение.
DO $$
DECLARE caught boolean;
BEGIN
    caught := false;
    BEGIN
        PERFORM pg_temp.assert_true('negative control false', false);
    EXCEPTION WHEN raise_exception THEN caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'assert_true accepted FALSE'; END IF;
    caught := false;
    BEGIN
        PERFORM pg_temp.assert_true('negative control null', NULL);
    EXCEPTION WHEN raise_exception THEN caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'assert_true accepted NULL'; END IF;
    caught := false;
    BEGIN
        PERFORM pg_temp.assert_numeric('negative control mismatch', 1, 2);
    EXCEPTION WHEN raise_exception THEN caught := true;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'assert_numeric accepted mismatch'; END IF;
END;
$$;
ROLLBACK;
\echo 'PASS: synthetic scenarios only; actual model not tested'
