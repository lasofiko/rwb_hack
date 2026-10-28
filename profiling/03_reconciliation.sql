\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
-- Focused follow-up to the completed raw profile: only SELECT and TEMP VIEW.
-- Explicit numeric casts assume the zero invalid-type findings of 01_raw_profile.sql.
BEGIN ISOLATION LEVEL REPEATABLE READ;
CREATE TEMP VIEW order_reconciliation AS
WITH i AS (
  SELECT order_id,count(*) item_rows,sum(price::numeric) price,
         sum(freight_value::numeric) freight
  FROM raw.order_items GROUP BY order_id
), p AS (
  SELECT order_id,count(*) payment_rows,sum(payment_value::numeric) payment
  FROM raw.order_payments GROUP BY order_id
)
SELECT o.order_id,o.order_status,i.item_rows,p.payment_rows,i.price,i.freight,p.payment,
       p.payment-(i.price+i.freight) delta
FROM raw.orders o LEFT JOIN i USING(order_id) LEFT JOIN p USING(order_id);
SELECT jsonb_build_object('section','reconciliation_by_status','status',order_status,
  'orders',count(*),'orders_without_items',count(*) FILTER(WHERE item_rows IS NULL),
  'orders_without_payment',count(*) FILTER(WHERE payment_rows IS NULL),
  'matched_orders',count(*) FILTER(WHERE delta=0),
  'different_orders',count(*) FILTER(WHERE delta<>0),
  'item_total',sum(price+freight),'payment_total',sum(payment),
  'matched_population_delta',sum(delta),
  'payment_on_orders_without_items',sum(payment) FILTER(WHERE item_rows IS NULL),
  'item_total_on_orders_without_payment',sum(price+freight) FILTER(WHERE payment_rows IS NULL))
FROM order_reconciliation GROUP BY order_status ORDER BY order_status;
SELECT jsonb_build_object('section','reconciliation_total','matched_orders',count(*) FILTER(WHERE delta=0),
  'different_orders',count(*) FILTER(WHERE delta<>0),
  'within_one_cent_nonzero',count(*) FILTER(WHERE delta<>0 AND abs(delta)<=0.01),
  'matched_population_delta',sum(delta),
  'payment_on_orders_without_items',sum(payment) FILTER(WHERE item_rows IS NULL),
  'item_total_on_orders_without_payment',sum(price+freight) FILTER(WHERE payment_rows IS NULL),
  'all_population_delta',sum(payment)-sum(price+freight)) FROM order_reconciliation;
SELECT jsonb_build_object('section','reconciliation_example','order_id',order_id,
  'status',order_status,'item_total',price+freight,'payment',payment,'delta',delta)
FROM order_reconciliation WHERE delta<>0 ORDER BY abs(delta) DESC,order_id LIMIT 5;
ROLLBACK;
