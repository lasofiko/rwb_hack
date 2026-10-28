\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT jsonb_build_object('section','runtime','facts',jsonb_build_object(
  'postgresql',version(),'database',current_database(),'profiled_at',current_timestamp,
  'handout_commit','3da32d149bfa14dca3fdb0c5863d0771c38efbfc'));
WITH missing AS (
  SELECT p.product_id,p.product_category_name FROM raw.products p
  WHERE p.product_category_name IS NULL OR NOT EXISTS
    (SELECT FROM raw.product_category_translation t WHERE t.product_category_name=p.product_category_name)
), item_totals AS (
  SELECT product_id,count(*) n,sum(price::numeric) price FROM raw.order_items GROUP BY product_id
)
SELECT jsonb_build_object('section','missing_translation','category',m.product_category_name,
  'products',count(*),'items',coalesce(sum(i.n),0),'item_price',coalesce(sum(i.price),0))
FROM missing m LEFT JOIN item_totals i USING(product_id)
GROUP BY m.product_category_name ORDER BY m.product_category_name NULLS FIRST;
WITH d AS (
  SELECT order_id,order_item_id::integer k,count(*) n FROM raw.order_items
  GROUP BY order_id,order_item_id::integer HAVING count(*)>1
), p AS (
  SELECT order_id,payment_sequential::integer k,count(*) n FROM raw.order_payments
  GROUP BY order_id,payment_sequential::integer HAVING count(*)>1
)
SELECT jsonb_build_object('section','typed_key_collision','item_groups',(SELECT count(*) FROM d),
  'payment_groups',(SELECT count(*) FROM p));
SELECT jsonb_build_object('section','payment_domain','zero_installments',
  count(*) FILTER(WHERE payment_installments::integer=0),
  'fractional_cents',count(*) FILTER(WHERE payment_value::numeric<>round(payment_value::numeric,2)))
FROM raw.order_payments;
WITH z AS (
  SELECT 'customer' source,customer_zip_code_prefix zip FROM raw.customers UNION ALL
  SELECT 'seller',seller_zip_code_prefix FROM raw.sellers
)
SELECT jsonb_build_object('section','zip','source',source,'length_min',min(length(zip)),
  'length_max',max(length(zip)),'non_digit_or_bad_length',count(*) FILTER(WHERE zip !~ '^[0-9]{1,5}$'))
FROM z GROUP BY source ORDER BY source;
SELECT jsonb_build_object('section','duplicate_review_example','review_id',review_id,
  'rows',count(*),'orders',count(DISTINCT order_id))
FROM raw.order_reviews GROUP BY review_id HAVING count(*)>1 ORDER BY review_id LIMIT 5;
ROLLBACK;
