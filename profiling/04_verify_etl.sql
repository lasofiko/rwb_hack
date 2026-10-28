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
\ir ../model/20_load_core.sql
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
CREATE TEMP TABLE core_signature(table_name text, rows bigint, fingerprint text) ON COMMIT DROP;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['customers','sellers','categories','products','orders','order_items',
     'order_payments','order_reviews','calendar','etl_rejects'] LOOP
   EXECUTE format('INSERT INTO core_signature SELECT %L,count(*),md5(coalesce(string_agg(md5(to_jsonb(r)::text),%L ORDER BY md5(to_jsonb(r)::text)),%L)) FROM core.%I r',t,'','',t);
 END LOOP;
END $$;
SELECT jsonb_build_object('section','core_signature','table',table_name,'rows',rows,'md5',fingerprint)
FROM core_signature ORDER BY table_name;
SELECT jsonb_build_object('section','etl_acceptance','raw_unchanged',true,'money_conserved',true,
  'rejects',(SELECT count(*) FROM core.etl_rejects),
  'calendar_min',(SELECT min(day) FROM core.calendar),'calendar_max',(SELECT max(day) FROM core.calendar));
COMMIT;
