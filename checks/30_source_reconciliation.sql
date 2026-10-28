\set ON_ERROR_STOP on
\ir lib/accepted_raw.sql

-- Контракт v1: text без trim/NULLIF; NULLIF(x, '') только перед приведением типа.
-- Сравнение мультимножеств значений, а не только количества или суммы.
-- Недопустимый тип в НЕотклонённой строке обязан завершить проверку ошибкой.
-- Никакого вывода отзывов/адресов: исключение содержит только имя проверки и count.
DO $$
DECLARE spec record; bad bigint;
BEGIN
    FOR spec IN SELECT * FROM (VALUES
    ('orders', $src$
        SELECT order_id, customer_id,
            order_status, nullif(order_purchase_timestamp, '')::timestamp,
            nullif(order_approved_at, '')::timestamp,
            nullif(order_delivered_carrier_date, '')::timestamp,
            nullif(order_delivered_customer_date, '')::timestamp,
            nullif(order_estimated_delivery_date, '')::timestamp
        FROM pg_temp.d_accepted_orders
    $src$, $dst$
        SELECT order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
            order_delivered_carrier_date, order_delivered_customer_date,
            order_estimated_delivery_date::timestamp FROM core.orders
    $dst$),
    ('customers_to_order_address', $src$
        SELECT customer_id, customer_unique_id,
            customer_zip_code_prefix, customer_city,
            customer_state FROM pg_temp.d_accepted_customers
    $src$, $dst$
        SELECT customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state
        FROM core.orders
    $dst$),
    ('customer_people', $src$
        SELECT DISTINCT customer_unique_id FROM pg_temp.d_accepted_customers
    $src$, $dst$ SELECT customer_unique_id FROM core.customers $dst$),
    ('repeat_customer_order_counts', $src$
        SELECT c.customer_unique_id, count(DISTINCT o.order_id)
        FROM pg_temp.d_accepted_orders o JOIN pg_temp.d_accepted_customers c
            ON c.customer_id = o.customer_id
        GROUP BY 1
    $src$, $dst$
        SELECT customer_unique_id, count(DISTINCT order_id) FROM core.orders GROUP BY customer_unique_id
    $dst$),
    ('order_items', $src$
        SELECT order_id, nullif(order_item_id, '')::integer,
            product_id, seller_id,
            nullif(shipping_limit_date, '')::timestamp,
            nullif(price, '')::numeric, nullif(freight_value, '')::numeric
        FROM pg_temp.d_accepted_order_items
    $src$, $dst$
        SELECT order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value
        FROM core.order_items
    $dst$),
    ('order_payments', $src$
        SELECT order_id, nullif(payment_sequential, '')::integer,
            payment_type, nullif(payment_installments, '')::integer,
            nullif(payment_value, '')::numeric FROM pg_temp.d_accepted_order_payments
    $src$, $dst$
        SELECT order_id, payment_sequential, payment_type, payment_installments, payment_value
        FROM core.order_payments
    $dst$),
    ('order_reviews', $src$
        SELECT review_id, order_id,
            nullif(review_score, '')::smallint, review_comment_title,
            review_comment_message, nullif(review_creation_date, '')::timestamp,
            nullif(review_answer_timestamp, '')::timestamp FROM pg_temp.d_accepted_order_reviews
    $src$, $dst$
        SELECT review_id, order_id, review_score, review_comment_title, review_comment_message,
            review_creation_date, review_answer_timestamp FROM core.order_reviews
    $dst$),
    ('products', $src$
        SELECT product_id, product_category_name,
            nullif(product_name_lenght, '')::integer,
            nullif(product_description_lenght, '')::integer,
            nullif(product_photos_qty, '')::integer, nullif(product_weight_g, '')::integer,
            nullif(product_length_cm, '')::integer, nullif(product_height_cm, '')::integer,
            nullif(product_width_cm, '')::integer FROM pg_temp.d_accepted_products
    $src$, $dst$
        SELECT product_id, product_category_name, product_name_length, product_description_length,
            product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm
        FROM core.products
    $dst$),
    ('sellers', $src$
        SELECT seller_id, seller_zip_code_prefix,
            seller_city, seller_state FROM pg_temp.d_accepted_sellers
    $src$, $dst$
        SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state FROM core.sellers
    $dst$),
    ('categories_union_with_untranslated', $src$
        WITH translations AS (
            SELECT product_category_name category,
                product_category_name_english english
            FROM pg_temp.d_accepted_product_category_translation
        ), names AS (
            SELECT category FROM translations
            UNION SELECT product_category_name
            FROM pg_temp.d_accepted_products WHERE product_category_name IS NOT NULL
        ) SELECT n.category, t.english FROM names n LEFT JOIN translations t ON t.category = n.category
    $src$, $dst$
        SELECT product_category_name, product_category_name_english FROM core.categories
    $dst$)
    ) AS expected(label, source_query, core_query) LOOP
        EXECUTE format($query$
            WITH src AS (%s), dst AS (%s), differences AS (
                (TABLE src EXCEPT ALL TABLE dst) UNION ALL (TABLE dst EXCEPT ALL TABLE src)
            ) SELECT count(*) FROM differences
        $query$, spec.source_query, spec.core_query) INTO bad;
        IF bad <> 0 THEN RAISE EXCEPTION 'source reconciliation %: % differing rows', spec.label, bad; END IF;
    END LOOP;
END;
$$;
