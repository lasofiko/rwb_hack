\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT jsonb_build_object('section','item_quantity','repeated_order_product_seller_groups',count(*),
  'rows_in_repeated_groups',sum(n),'excess_units',sum(n-1),'max_units',max(n))
FROM (SELECT order_id,product_id,seller_id,count(*) n FROM raw.order_items
 GROUP BY order_id,product_id,seller_id HAVING count(*)>1) d;
WITH cities AS (
 SELECT 'customers' source,customer_city city FROM raw.customers UNION ALL
 SELECT 'sellers',seller_city FROM raw.sellers
)
SELECT jsonb_build_object('section','city_format','source',source,
 'padded_rows',count(*) FILTER(WHERE city<>btrim(city)),
 'non_lowercase_rows',count(*) FILTER(WHERE city<>lower(city)),
 'distinct_names',count(DISTINCT city),'distinct_lower_trim_names',count(DISTINCT lower(btrim(city))))
FROM cities GROUP BY source ORDER BY source;
SELECT jsonb_build_object('section','estimated_delivery','non_midnight_rows',
 count(*) FILTER(WHERE order_estimated_delivery_date::timestamp::time<>time '00:00:00')) FROM raw.orders;
ROLLBACK;
