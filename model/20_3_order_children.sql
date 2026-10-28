-- B / contract v1: items, payments, reviews and rejected source rows.
-- FK failures are quarantined after parents have been loaded, without losing rows to INNER JOIN.
DO $$
DECLARE f record;
BEGIN
 FOR f IN SELECT * FROM (VALUES
   ('order_items','order_id','orders','order_id'),
   ('order_items','product_id','products','product_id'),
   ('order_items','seller_id','sellers','seller_id'),
   ('order_payments','order_id','orders','order_id'),
   ('order_reviews','order_id','orders','order_id')) x(child,col,parent,parent_col)
 LOOP
   EXECUTE format($q$
     UPDATE pg_temp._b_stage s SET reasons=array_append(s.reasons,%L)
     WHERE s.source_table=%L AND cardinality(s.reasons)=0 AND NOT EXISTS
      (SELECT FROM core.%I p WHERE p.%I=s.data->>%L)
   $q$,'orphan:'||f.parent,f.child,f.parent,f.parent_col,f.col);
 END LOOP;
END $$;
INSERT INTO core.order_items(order_id,order_item_id,product_id,seller_id,shipping_limit_date,price,freight_value)
SELECT r.order_id,r.order_item_id,r.product_id,r.seller_id,r.shipping_limit_date,r.price,r.freight_value
FROM pg_temp._b_stage s CROSS JOIN LATERAL jsonb_populate_record(NULL::core.order_items,CASE WHEN s.source_table='order_items' AND cardinality(s.reasons)=0 THEN s.data ELSE '{}'::jsonb END) r
WHERE s.source_table='order_items' AND cardinality(s.reasons)=0;
INSERT INTO core.order_payments(order_id,payment_sequential,payment_type,payment_installments,payment_value)
SELECT r.order_id,r.payment_sequential,r.payment_type,r.payment_installments,r.payment_value
FROM pg_temp._b_stage s CROSS JOIN LATERAL jsonb_populate_record(NULL::core.order_payments,CASE WHEN s.source_table='order_payments' AND cardinality(s.reasons)=0 THEN s.data ELSE '{}'::jsonb END) r
WHERE s.source_table='order_payments' AND cardinality(s.reasons)=0;
INSERT INTO core.order_reviews(review_id,order_id,review_score,review_comment_title,review_comment_message,
    review_creation_date,review_answer_timestamp)
SELECT r.review_id,r.order_id,r.review_score,r.review_comment_title,r.review_comment_message,
    r.review_creation_date,r.review_answer_timestamp
FROM pg_temp._b_stage s CROSS JOIN LATERAL jsonb_populate_record(NULL::core.order_reviews,CASE WHEN s.source_table='order_reviews' AND cardinality(s.reasons)=0 THEN s.data ELSE '{}'::jsonb END) r
WHERE s.source_table='order_reviews' AND cardinality(s.reasons)=0;
INSERT INTO core.etl_rejects(source_table,source_key,reason,payload)
SELECT source_table,source_key,reasons[1],payload FROM pg_temp._b_stage
WHERE cardinality(reasons)>0;
