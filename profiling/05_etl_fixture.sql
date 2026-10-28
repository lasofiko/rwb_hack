\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on
-- Dedicated empty fixture DB only; synthetic rows never touch the profiled raw DB.
BEGIN;
CREATE SCHEMA raw;
CREATE SCHEMA core;
\ir ../scripts/init/02_raw_ddl.sql
INSERT INTO raw.customers(customer_id,customer_unique_id,customer_zip_code_prefix,customer_city) VALUES
 ('c1','u1','01234','first city'),('c2','u1','99999','second city'),('c3','u3','12345','unused'),
 ('cdup','udup','12345','duplicate'),('cdup','udup','12345','duplicate');
INSERT INTO raw.orders(order_id,customer_id,order_status,order_purchase_timestamp,
 order_approved_at,order_delivered_carrier_date,order_estimated_delivery_date) VALUES
 ('o1','c1','delivered','2016-09-01 12:00:00','2016-09-02 12:00:00','2016-09-01 13:00:00','2016-09-15 00:00:00'),
 ('o2','c2','canceled','2016-11-01 10:00:00',NULL,NULL,'2020-03-01 00:00:00'),
 ('obad','c_missing','created','2016-10-01 10:00:00',NULL,NULL,NULL),
 ('otype','c3','created','garbage',NULL,NULL,NULL),
 ('odup','x1','created','2016-10-01 10:00:00',NULL,NULL,NULL),
 ('odup','x2','created','2016-10-01 10:00:00',NULL,NULL,NULL);
INSERT INTO raw.customers(customer_id,customer_unique_id) VALUES ('c4','u4');
INSERT INTO raw.orders(order_id,customer_id,order_status,order_purchase_timestamp,order_estimated_delivery_date)
VALUES ('otime','c4','created','2016-10-01 10:00:00','2016-10-02 12:00:00');
INSERT INTO raw.sellers(seller_id,seller_city) VALUES ('s1','Mixed CITY'),('sdup','a'),('sdup','b');
INSERT INTO raw.product_category_translation(product_category_name,product_category_name_english) VALUES
 ('cat','translated'),('dup_cat','a'),('dup_cat','b'),(NULL,'missing key');
INSERT INTO raw.products(product_id,product_category_name,product_name_lenght,product_weight_g) VALUES
 ('p1','cat','3','100'),('p2',NULL,NULL,NULL),('p3','untranslated','4','200'),('pbad','cat','3','not-an-int');
INSERT INTO raw.order_items(order_id,order_item_id,product_id,seller_id,price,freight_value) VALUES
 ('o1','1','p1','s1','10.123','0'),('o1','2','p1','s1','20','2'),('o2','1','p3','s1','30','3'),
 ('o1','3','missing','s1','1','0'),('o1','4','p1','missing','1','0'),
 ('o1','5','pbad','s1','1','0'),('o1','6','p1','s1','oops','0'),
 ('missing','1','p1','s1','1','0'),('o1','7','p1','sdup','1','0');
INSERT INTO raw.order_payments(order_id,payment_sequential,payment_type,payment_installments,payment_value) VALUES
 ('o1','1','not_defined','0','0'),('o1','2','voucher','1','5'),('o2','1','credit_card','1','10'),
 ('o1','3','voucher','1','1'),('o1','03','voucher','1','2'),('missing','1','voucher','1','1'),
 ('o1','4','voucher','1','garbage'),('o1','5','voucher','1','-1'),('o1','6','voucher','1','NaN'),
 ('o1','7','   ','1','1');
INSERT INTO raw.order_reviews(review_id,order_id,review_score,review_comment_title,review_comment_message) VALUES
 ('r1','o1','5','  keep title  ','  keep message  '),('r1','o2','1','   ',' '),
 ('rd','o1','4',NULL,NULL),('rd','o1','3',NULL,NULL),
 ('rb','o1','9',NULL,NULL),('rt','o1','oops',NULL,NULL);
\ir ../model/10_ddl.sql
\ir ../model/20_load_core.sql
DO $$ BEGIN
 IF (SELECT count(*) FROM core.orders)<>2 OR (SELECT count(*) FROM core.customers)<>1
 THEN RAISE EXCEPTION 'fixture: order/person grain'; END IF;
 IF (SELECT count(*) FROM core.order_items)<>3 OR
    (SELECT price FROM core.order_items WHERE order_id='o1' AND order_item_id=1)<>10.123
 THEN RAISE EXCEPTION 'fixture: money precision or repeated item loss'; END IF;
 IF (SELECT count(*) FROM core.order_reviews WHERE review_id='r1')<>2 OR
    (SELECT review_comment_message FROM core.order_reviews WHERE order_id='o1') IS DISTINCT FROM '  keep message  '
 OR (SELECT review_comment_title FROM core.order_reviews WHERE order_id='o2') IS NOT NULL
 THEN RAISE EXCEPTION 'fixture: review grain or text normalization'; END IF;
 IF (SELECT customer_city FROM core.orders WHERE order_id='o1')<>'first city'
 OR (SELECT customer_city FROM core.orders WHERE order_id='o2')<>'second city'
 OR (SELECT customer_zip_code_prefix FROM core.orders WHERE order_id='o1')<>'01234'
 THEN RAISE EXCEPTION 'fixture: order address or ZIP'; END IF;
 IF (SELECT count(*) FROM core.order_payments)<>3 OR NOT EXISTS
 (SELECT FROM core.order_payments WHERE payment_type='not_defined' AND payment_installments=0 AND payment_value=0)
 THEN RAISE EXCEPTION 'fixture: payment normalization or multiplicity'; END IF;
 IF (SELECT count(*) FROM core.etl_rejects WHERE source_table='order_payments' AND reason LIKE '%duplicate_key%')<>2
 OR NOT EXISTS (SELECT FROM core.etl_rejects WHERE reason LIKE '%bad_type:%')
 OR NOT EXISTS (SELECT FROM core.etl_rejects WHERE reason LIKE '%orphan_fk:%')
 OR NOT EXISTS (SELECT FROM core.etl_rejects WHERE reason LIKE '%negative_money:%')
 OR NOT EXISTS (SELECT FROM core.etl_rejects WHERE reason LIKE '%nonfinite:%')
 OR NOT EXISTS (SELECT FROM core.etl_rejects WHERE reason LIKE '%non_midnight:%')
 OR NOT EXISTS (SELECT FROM core.etl_rejects WHERE reason LIKE '%missing_required:%')
 THEN RAISE EXCEPTION 'fixture: missing quarantine reason'; END IF;
 IF (SELECT product_category_name FROM core.products WHERE product_id='p2') IS NOT NULL
 OR NOT EXISTS (SELECT FROM core.categories WHERE product_category_name='untranslated' AND product_category_name_english IS NULL)
 THEN RAISE EXCEPTION 'fixture: category NULL/fallback'; END IF;
 IF (SELECT min(day) FROM core.calendar)<>date '2016-09-01'
 OR (SELECT max(day) FROM core.calendar)<>date '2020-03-31'
 OR (SELECT count(*) FROM core.calendar WHERE month_start='2016-10-01')<>31
 THEN RAISE EXCEPTION 'fixture: calendar bounds or empty month'; END IF;
 IF NOT EXISTS (SELECT FROM core.orders WHERE order_delivered_carrier_date<order_approved_at)
 THEN RAISE EXCEPTION 'fixture: chronology was rewritten'; END IF;
END $$;
SELECT jsonb_build_object('section','fixture_acceptance','passed',true,
 'orders',(SELECT count(*) FROM core.orders),'people',(SELECT count(*) FROM core.customers),
 'items',(SELECT count(*) FROM core.order_items),'payments',(SELECT count(*) FROM core.order_payments),
 'reviews',(SELECT count(*) FROM core.order_reviews),'rejects',(SELECT count(*) FROM core.etl_rejects));
ROLLBACK;
