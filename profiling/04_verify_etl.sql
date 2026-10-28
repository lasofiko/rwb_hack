\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on
BEGIN;
CREATE TEMP TABLE raw_before(source_table text, fingerprint text) ON COMMIT DROP;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['orders','customers','sellers','products','order_items',
     'order_payments','order_reviews','product_category_translation'] LOOP
   EXECUTE format('INSERT INTO raw_before SELECT %L, md5(string_agg(md5(to_jsonb(r)::text),%L ORDER BY md5(to_jsonb(r)::text))) FROM raw.%I r',t,'',t);
 END LOOP;
END $$;
DROP SCHEMA IF EXISTS mart CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA core;
CREATE SCHEMA mart;
\ir ../model/10_ddl.sql
\ir ../model/20_1_dims.sql
\ir ../model/20_2_orders.sql
\ir ../model/20_3_order_children.sql
\ir ../model/20_4_calendar.sql
DO $$ DECLARE t text; actual text; expected text; BEGIN
 FOR t,expected IN SELECT source_table,fingerprint FROM raw_before LOOP
   EXECUTE format('SELECT md5(string_agg(md5(to_jsonb(r)::text),%L ORDER BY md5(to_jsonb(r)::text))) FROM raw.%I r','',t) INTO actual;
   IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'raw changed: %',t; END IF;
 END LOOP;
 IF EXISTS (SELECT FROM core.etl_rejects) THEN RAISE EXCEPTION 'Snapshot unexpectedly rejected rows'; END IF;
 IF (SELECT sum(price) FROM core.order_items) IS DISTINCT FROM (SELECT sum(price::numeric) FROM raw.order_items)
 OR (SELECT sum(freight_value) FROM core.order_items) IS DISTINCT FROM (SELECT sum(freight_value::numeric) FROM raw.order_items)
 OR (SELECT sum(payment_value) FROM core.order_payments) IS DISTINCT FROM (SELECT sum(payment_value::numeric) FROM raw.order_payments)
 THEN RAISE EXCEPTION 'Money conservation failed'; END IF;
END $$;
DO $$ DECLARE t text; expected bigint; actual bigint; BEGIN
 FOR t,expected IN SELECT * FROM (VALUES
  ('customers',96096),('orders',99441),('order_items',112650),('order_payments',103886),
  ('order_reviews',99224),('products',32951),('sellers',3095),('categories',73),
  ('calendar',821),('etl_rejects',0)) x(name,n) LOOP
   EXECUTE format('SELECT count(*) FROM core.%I',t) INTO actual;
   IF actual<>expected THEN RAISE EXCEPTION 'contract v1 rows %: % <> %',t,actual,expected; END IF;
 END LOOP;
 IF (SELECT count(DISTINCT customer_id) FROM core.orders)<>99441
 OR (SELECT count(*) FROM core.products WHERE product_category_name IS NULL)<>610
 OR (SELECT count(*) FROM core.categories WHERE product_category_name_english IS NULL)<>2
 OR (SELECT count(DISTINCT month_start) FROM core.calendar)<>27
 OR (SELECT min(day) FROM core.calendar)<>date '2016-09-01'
 OR (SELECT max(day) FROM core.calendar)<>date '2018-11-30'
 THEN RAISE EXCEPTION 'contract v1 identity/category/calendar'; END IF;
 IF EXISTS (SELECT FROM raw.order_reviews r JOIN core.order_reviews c USING(review_id,order_id)
   WHERE c.review_comment_title IS DISTINCT FROM r.review_comment_title
      OR c.review_comment_message IS DISTINCT FROM r.review_comment_message)
 OR EXISTS (SELECT FROM raw.customers r JOIN core.orders c USING(customer_id)
   WHERE c.customer_unique_id IS DISTINCT FROM r.customer_unique_id
      OR c.customer_city IS DISTINCT FROM r.customer_city
      OR c.customer_state IS DISTINCT FROM r.customer_state
      OR c.customer_zip_code_prefix IS DISTINCT FROM r.customer_zip_code_prefix)
 OR EXISTS (SELECT FROM raw.sellers r JOIN core.sellers c USING(seller_id)
   WHERE c.seller_city IS DISTINCT FROM r.seller_city OR c.seller_state IS DISTINCT FROM r.seller_state
      OR c.seller_zip_code_prefix IS DISTINCT FROM r.seller_zip_code_prefix)
 THEN RAISE EXCEPTION 'contract v1 text changed'; END IF;
END $$;
CREATE TEMP TABLE core_signature(table_name text, rows bigint, fingerprint text) ON COMMIT DROP;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['customers','sellers','categories','products','orders','order_items',
     'order_payments','order_reviews','calendar','etl_rejects'] LOOP
   EXECUTE format('INSERT INTO core_signature SELECT %L,count(*),md5(coalesce(string_agg(md5(to_jsonb(r)::text),%L ORDER BY md5(to_jsonb(r)::text)),%L)) FROM core.%I r',t,'','',t);
 END LOOP;
END $$;
SELECT jsonb_build_object('section','core_signature','table',table_name,'rows',rows,'md5',fingerprint)
FROM core_signature ORDER BY table_name;
SELECT jsonb_build_object('section','etl_acceptance','contract','v1','raw_unchanged',true,'money_conserved',true,
  'text_preserved',true,'expected_counts_match',true,
  'rejects',(SELECT count(*) FROM core.etl_rejects),
  'calendar_min',(SELECT min(day) FROM core.calendar),'calendar_max',(SELECT max(day) FROM core.calendar));
COMMIT;
