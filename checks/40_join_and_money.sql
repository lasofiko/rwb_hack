\set ON_ERROR_STOP on
\ir lib/assertions.sql

SELECT pg_temp.assert_true('money is finite and nonnegative', NOT EXISTS (
    SELECT 1 FROM core.order_items
    WHERE price IS NULL OR freight_value IS NULL OR price < 0 OR freight_value < 0
       OR price IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
       OR freight_value IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
    UNION ALL
    SELECT 1 FROM core.order_payments WHERE payment_value IS NULL OR payment_value < 0
       OR payment_value IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
));

-- Два разных зерна: позиции для денег продавца, заказ для платежей/отзывов.
CREATE TEMP VIEW d_item_dimensions AS
SELECT i.*, p.product_category_name, c.product_category_name_english,
       s.seller_city, s.seller_state, o.order_status, o.order_purchase_timestamp
FROM core.order_items i JOIN core.orders o USING (order_id)
JOIN core.products p USING (product_id) JOIN core.sellers s USING (seller_id)
LEFT JOIN core.categories c ON c.product_category_name = p.product_category_name;

SELECT pg_temp.assert_numeric('dimension joins preserve item rows',
    (SELECT count(*)::numeric FROM d_item_dimensions), (SELECT count(*)::numeric FROM core.order_items));
SELECT pg_temp.assert_numeric('dimension joins preserve price',
    (SELECT sum(price) FROM d_item_dimensions), (SELECT sum(price) FROM core.order_items));
SELECT pg_temp.assert_numeric('dimension joins preserve freight',
    (SELECT sum(freight_value) FROM d_item_dimensions), (SELECT sum(freight_value) FROM core.order_items));

CREATE TEMP VIEW d_order_aggregates AS
WITH items AS (
    SELECT order_id, count(*) n, sum(price) price, sum(freight_value) freight
    FROM core.order_items GROUP BY order_id
), payments AS (
    SELECT order_id, count(*) n, sum(payment_value) amount FROM core.order_payments GROUP BY order_id
), reviews AS (
    SELECT order_id, count(*) n FROM core.order_reviews GROUP BY order_id
)
SELECT o.order_id, coalesce(i.n, 0) item_count, i.price, i.freight,
    coalesce(p.n, 0) payment_count, p.amount,
    coalesce(r.n, 0) review_count
FROM core.orders o LEFT JOIN items i USING (order_id)
LEFT JOIN payments p USING (order_id) LEFT JOIN reviews r USING (order_id);

SELECT pg_temp.assert_numeric('aggregate joins preserve order grain',
    (SELECT count(*)::numeric FROM d_order_aggregates), (SELECT count(*)::numeric FROM core.orders));
SELECT pg_temp.assert_numeric('order aggregates preserve item rows',
    (SELECT coalesce(sum(item_count), 0) FROM d_order_aggregates), (SELECT count(*)::numeric FROM core.order_items));
SELECT pg_temp.assert_numeric('order aggregates preserve price',
    (SELECT sum(price) FROM d_order_aggregates), (SELECT sum(price) FROM core.order_items));
SELECT pg_temp.assert_numeric('order aggregates preserve freight',
    (SELECT sum(freight) FROM d_order_aggregates), (SELECT sum(freight_value) FROM core.order_items));
SELECT pg_temp.assert_numeric('order aggregates preserve payment rows',
    (SELECT coalesce(sum(payment_count), 0) FROM d_order_aggregates), (SELECT count(*)::numeric FROM core.order_payments));
SELECT pg_temp.assert_numeric('order aggregates preserve payments',
    (SELECT sum(amount) FROM d_order_aggregates), (SELECT sum(payment_value) FROM core.order_payments));
SELECT pg_temp.assert_numeric('order aggregates preserve review rows',
    (SELECT coalesce(sum(review_count), 0) FROM d_order_aggregates), (SELECT count(*)::numeric FROM core.order_reviews));

-- NULL-категория остаётся отдельной группой; отсутствие перевода не склеивает категории.
SELECT pg_temp.assert_numeric('delivered category sum includes unknown',
    (SELECT sum(revenue) FROM (
        SELECT product_category_name, sum(price) revenue FROM d_item_dimensions
        WHERE order_status = 'delivered' GROUP BY product_category_name
    ) categories),
    (SELECT sum(i.price) FROM core.order_items i JOIN core.orders o USING (order_id)
     WHERE o.order_status = 'delivered'));
SELECT pg_temp.assert_numeric('delivered seller sum uses own items',
    (SELECT sum(revenue) FROM (
        SELECT seller_id, sum(price) revenue FROM d_item_dimensions
        WHERE order_status = 'delivered' GROUP BY seller_id
    ) sellers),
    (SELECT sum(i.price) FROM core.order_items i JOIN core.orders o USING (order_id)
     WHERE o.order_status = 'delivered'));
