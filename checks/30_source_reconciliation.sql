\set ON_ERROR_STOP on
\ir lib/accepted_raw.sql

-- Сравнение мультимножеств значений, а не только количества или суммы.
-- Недопустимый тип в НЕотклонённой строке обязан завершить проверку ошибкой.
-- Никакого вывода отзывов/адресов: исключение содержит только имя проверки и count.
DO $$
DECLARE spec record; bad bigint;
BEGIN
    FOR spec IN SELECT * FROM (VALUES
    ('orders', $src$
        SELECT nullif(btrim(order_id), ''), nullif(btrim(customer_id), ''),
            nullif(btrim(order_status), ''), nullif(btrim(order_purchase_timestamp), '')::timestamp,
            nullif(btrim(order_approved_at), '')::timestamp,
            nullif(btrim(order_delivered_carrier_date), '')::timestamp,
            nullif(btrim(order_delivered_customer_date), '')::timestamp,
            nullif(btrim(order_estimated_delivery_date), '')::timestamp
        FROM pg_temp.d_accepted_orders
    $src$, $dst$
        SELECT order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
            order_delivered_carrier_date, order_delivered_customer_date,
            order_estimated_delivery_date::timestamp FROM core.orders
    $dst$),
    ('customers_to_order_address', $src$
        SELECT nullif(btrim(customer_id), ''), nullif(btrim(customer_unique_id), ''),
            nullif(btrim(customer_zip_code_prefix), ''), nullif(btrim(customer_city), ''),
            nullif(btrim(customer_state), '') FROM pg_temp.d_accepted_customers
    $src$, $dst$
        SELECT customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state
        FROM core.orders
    $dst$),
    ('customer_people', $src$
        SELECT DISTINCT nullif(btrim(customer_unique_id), '') FROM pg_temp.d_accepted_customers
    $src$, $dst$ SELECT customer_unique_id FROM core.customers $dst$),
    ('repeat_customer_order_counts', $src$
        SELECT nullif(btrim(c.customer_unique_id), ''), count(DISTINCT nullif(btrim(o.order_id), ''))
        FROM pg_temp.d_accepted_orders o JOIN pg_temp.d_accepted_customers c
            ON nullif(btrim(c.customer_id), '') = nullif(btrim(o.customer_id), '')
        GROUP BY 1
    $src$, $dst$
        SELECT customer_unique_id, count(DISTINCT order_id) FROM core.orders GROUP BY customer_unique_id
    $dst$),
    ('order_items', $src$
        SELECT nullif(btrim(order_id), ''), nullif(btrim(order_item_id), '')::integer,
            nullif(btrim(product_id), ''), nullif(btrim(seller_id), ''),
            nullif(btrim(shipping_limit_date), '')::timestamp,
            nullif(btrim(price), '')::numeric, nullif(btrim(freight_value), '')::numeric
        FROM pg_temp.d_accepted_order_items
    $src$, $dst$
        SELECT order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value
        FROM core.order_items
    $dst$),
    ('order_payments', $src$
        SELECT nullif(btrim(order_id), ''), nullif(btrim(payment_sequential), '')::integer,
            nullif(btrim(payment_type), ''), nullif(btrim(payment_installments), '')::integer,
            nullif(btrim(payment_value), '')::numeric FROM pg_temp.d_accepted_order_payments
    $src$, $dst$
        SELECT order_id, payment_sequential, payment_type, payment_installments, payment_value
        FROM core.order_payments
    $dst$),
    ('order_reviews', $src$
        SELECT nullif(btrim(review_id), ''), nullif(btrim(order_id), ''),
            nullif(btrim(review_score), '')::smallint, nullif(btrim(review_comment_title), ''),
            nullif(btrim(review_comment_message), ''), nullif(btrim(review_creation_date), '')::timestamp,
            nullif(btrim(review_answer_timestamp), '')::timestamp FROM pg_temp.d_accepted_order_reviews
    $src$, $dst$
        SELECT review_id, order_id, review_score, review_comment_title, review_comment_message,
            review_creation_date, review_answer_timestamp FROM core.order_reviews
    $dst$),
    ('products', $src$
        SELECT nullif(btrim(product_id), ''), nullif(btrim(product_category_name), ''),
            nullif(btrim(product_name_lenght), '')::integer,
            nullif(btrim(product_description_lenght), '')::integer,
            nullif(btrim(product_photos_qty), '')::integer, nullif(btrim(product_weight_g), '')::integer,
            nullif(btrim(product_length_cm), '')::integer, nullif(btrim(product_height_cm), '')::integer,
            nullif(btrim(product_width_cm), '')::integer FROM pg_temp.d_accepted_products
    $src$, $dst$
        SELECT product_id, product_category_name, product_name_length, product_description_length,
            product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm
        FROM core.products
    $dst$),
    ('sellers', $src$
        SELECT nullif(btrim(seller_id), ''), nullif(btrim(seller_zip_code_prefix), ''),
            nullif(btrim(seller_city), ''), nullif(btrim(seller_state), '') FROM pg_temp.d_accepted_sellers
    $src$, $dst$
        SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state FROM core.sellers
    $dst$),
    ('categories_union_with_untranslated', $src$
        WITH translations AS (
            SELECT nullif(btrim(product_category_name), '') category,
                nullif(btrim(product_category_name_english), '') english
            FROM pg_temp.d_accepted_product_category_translation
        ), names AS (
            SELECT category FROM translations
            UNION SELECT nullif(btrim(product_category_name), '')
            FROM pg_temp.d_accepted_products WHERE nullif(btrim(product_category_name), '') IS NOT NULL
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
