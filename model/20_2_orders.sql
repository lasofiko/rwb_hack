-- B / contract v1: orders and the address at order time.
-- Unique, valid raw customer records are the order's address, never the latest address of a person.
CREATE TEMP TABLE _b_customer ON COMMIT DROP AS
SELECT data->>'customer_id' customer_id,data FROM pg_temp._b_stage
WHERE source_table='customers' AND cardinality(reasons)=0;
CREATE UNIQUE INDEX ON _b_customer(customer_id);
UPDATE pg_temp._b_stage s SET reasons=array_append(s.reasons,'orphan:customers')
WHERE s.source_table='orders' AND cardinality(s.reasons)=0
AND NOT EXISTS (SELECT FROM pg_temp._b_customer c WHERE c.customer_id=s.data->>'customer_id');
INSERT INTO core.orders(order_id,customer_id,customer_unique_id,order_status,order_purchase_timestamp,
    order_approved_at,order_delivered_carrier_date,order_delivered_customer_date,order_estimated_delivery_date,
    customer_zip_code_prefix,customer_city,customer_state)
SELECT r.order_id,r.customer_id,r.customer_unique_id,r.order_status,r.order_purchase_timestamp,
    r.order_approved_at,r.order_delivered_carrier_date,r.order_delivered_customer_date,r.order_estimated_delivery_date,
    r.customer_zip_code_prefix,r.customer_city,r.customer_state
FROM pg_temp._b_stage s JOIN pg_temp._b_customer c ON c.customer_id=s.data->>'customer_id'
CROSS JOIN LATERAL jsonb_populate_record(NULL::core.orders,s.data||c.data) r
WHERE s.source_table='orders' AND cardinality(s.reasons)=0;
-- Under the contract raw.customers maps 1:1 to accepted orders; account for unused records.
UPDATE pg_temp._b_stage s SET reasons=array_append(s.reasons,'orphan:orders')
WHERE s.source_table='customers' AND cardinality(s.reasons)=0
AND NOT EXISTS (SELECT FROM core.orders o WHERE o.customer_id=s.data->>'customer_id');
DELETE FROM core.customers c WHERE NOT EXISTS
 (SELECT FROM core.orders o WHERE o.customer_unique_id=c.customer_unique_id);
