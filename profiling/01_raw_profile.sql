\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on
-- PostgreSQL 16+. Only temporary objects are written; raw is never mutated.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL datestyle = 'ISO, YMD';
CREATE TEMP TABLE profile_result(section text, subject text, facts jsonb);
CREATE TEMP TABLE source_table(name text PRIMARY KEY, keys text[]);
INSERT INTO source_table VALUES
('orders', ARRAY['order_id']),
('order_items', ARRAY['order_id','order_item_id']),
('order_payments', ARRAY['order_id','payment_sequential']),
('order_reviews', ARRAY['review_id','order_id']),
('products', ARRAY['product_id']),
('sellers', ARRAY['seller_id']),
('customers', ARRAY['customer_id']),
('product_category_translation', ARRAY['product_category_name']);
DO $$
DECLARE t record; c record; k text; missing text; dtype text;
BEGIN
  IF current_setting('server_version_num')::int < 160000 THEN
    RAISE EXCEPTION 'PostgreSQL 16+ required';
  END IF;
  FOR t IN SELECT * FROM source_table ORDER BY name LOOP
    IF to_regclass(format('raw.%I', t.name)) IS NULL THEN
      RAISE EXCEPTION 'Missing raw.%', t.name;
    END IF;
    EXECUTE format($q$
      INSERT INTO profile_result
      SELECT 'table', %L, jsonb_build_object('rows', count(*),
        'source_files', array_agg(DISTINCT _source_file),
        'loaded_at_min', min(_loaded_at), 'loaded_at_max', max(_loaded_at))
      FROM raw.%I
    $q$, t.name, t.name);
    SELECT string_agg(format('NULLIF(btrim(%I), %L)', key, ''), ', '),
           string_agg(format('NULLIF(btrim(%I), %L) IS NULL', key, ''), ' OR ')
      INTO k, missing FROM unnest(t.keys) key;
    EXECUTE format($q$
      INSERT INTO profile_result
      SELECT 'key', %L, jsonb_build_object(
        'columns', to_jsonb(%L::text[]),
        'missing_key_rows', (SELECT count(*) FROM raw.%I WHERE %s),
        'duplicate_groups', count(*), 'duplicate_excess_rows', coalesce(sum(n-1),0))
      FROM (SELECT count(*) n FROM raw.%I GROUP BY %s HAVING count(*)>1) d
    $q$, t.name, t.keys, t.name, missing, t.name, k);
    EXECUTE format($q$
      INSERT INTO profile_result
      SELECT 'exact_duplicate', %L, jsonb_build_object(
        'groups', count(*), 'excess_rows', coalesce(sum(n-1),0))
      FROM (SELECT count(*) n FROM raw.%I r
            GROUP BY to_jsonb(r) - '_source_file' - '_loaded_at' HAVING count(*)>1) d
    $q$, t.name, t.name);
    FOR c IN SELECT column_name FROM information_schema.columns
      WHERE table_schema='raw' AND table_name=t.name AND column_name NOT LIKE '\_%' ESCAPE '\'
      ORDER BY ordinal_position LOOP
      dtype := CASE
        WHEN c.column_name IN ('order_item_id','payment_sequential','payment_installments','review_score',
          'product_name_lenght','product_description_lenght','product_photos_qty',
          'product_weight_g','product_length_cm','product_height_cm','product_width_cm') THEN 'integer'
        WHEN c.column_name IN ('price','freight_value','payment_value') THEN 'numeric'
        WHEN c.column_name LIKE '%timestamp' OR c.column_name LIKE '%_date'
          OR c.column_name='order_approved_at' THEN 'timestamp without time zone'
        ELSE 'text' END;
      EXECUTE format($q$
        INSERT INTO profile_result
        SELECT 'column', %L, jsonb_build_object('target_type_candidate', %L,
          'null_rows', count(*) FILTER (WHERE v IS NULL),
          'empty_rows', count(*) FILTER (WHERE v = ''),
          'whitespace_only_rows', count(*) FILTER (WHERE v <> '' AND btrim(v) = ''),
          'padded_rows', count(*) FILTER (WHERE v <> btrim(v)),
          'distinct_nonblank', count(DISTINCT NULLIF(btrim(v),'')),
          'invalid_type_rows', count(*) FILTER (WHERE NULLIF(btrim(v),'') IS NOT NULL
            AND NOT pg_input_is_valid(btrim(v), %L)))
        FROM (SELECT %I v FROM raw.%I) d
      $q$, t.name||'.'||c.column_name, dtype, dtype, c.column_name, t.name);
      IF dtype IN ('integer','numeric','timestamp without time zone') THEN
        EXECUTE format($q$
          INSERT INTO profile_result
          SELECT 'typed_range', %L, jsonb_build_object('min', min(v), 'max', max(v),
            'nonfinite_rows', count(*) FILTER (WHERE lower(v::text) IN ('nan','infinity','-infinity')))
          FROM (SELECT CASE WHEN pg_input_is_valid(NULLIF(btrim(%I),''), %L)
            THEN NULLIF(btrim(%I),'')::%s END v FROM raw.%I) d
        $q$, t.name||'.'||c.column_name, c.column_name, dtype, c.column_name, dtype, t.name);
      END IF;
    END LOOP;
  END LOOP;
END $$;
-- Distinct parent keys keep relationship checks from multiplying child rows.
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT * FROM (VALUES
    ('orders','customer_id','customers','customer_id'),
    ('order_items','order_id','orders','order_id'),
    ('order_items','product_id','products','product_id'),
    ('order_items','seller_id','sellers','seller_id'),
    ('order_payments','order_id','orders','order_id'),
    ('order_reviews','order_id','orders','order_id'),
    ('products','product_category_name','product_category_translation','product_category_name')
  ) v(child, child_key, parent, parent_key) LOOP
    EXECUTE format($q$
      INSERT INTO profile_result
      SELECT 'relationship', %L, jsonb_build_object(
        'missing_reference_rows', count(*) FILTER (WHERE NULLIF(btrim(c.%I),'') IS NULL),
        'orphan_rows', count(*) FILTER (WHERE NULLIF(btrim(c.%I),'') IS NOT NULL AND p.k IS NULL))
      FROM raw.%I c
      LEFT JOIN (SELECT DISTINCT NULLIF(btrim(%I),'') k FROM raw.%I) p
        ON p.k=NULLIF(btrim(c.%I),'')
    $q$, f.child||'.'||f.child_key||' -> '||f.parent||'.'||f.parent_key,
      f.child_key, f.child_key, f.child, f.parent_key, f.parent, f.child_key);
  END LOOP;
END $$;
INSERT INTO profile_result
SELECT 'distribution', 'orders.order_status', jsonb_object_agg(coalesce(order_status,'<NULL>'),n)
FROM (SELECT order_status, count(*) n FROM raw.orders GROUP BY order_status) d;
INSERT INTO profile_result
SELECT 'distribution', 'order_payments.payment_type', jsonb_object_agg(coalesce(payment_type,'<NULL>'),n)
FROM (SELECT payment_type, count(*) n FROM raw.order_payments GROUP BY payment_type) d;
INSERT INTO profile_result
SELECT 'distribution', 'order_reviews.review_score', jsonb_object_agg(coalesce(review_score,'<NULL>'),n)
FROM (SELECT review_score, count(*) n FROM raw.order_reviews GROUP BY review_score) d;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['order_items','order_payments','order_reviews'] LOOP
    EXECUTE format($q$
      INSERT INTO profile_result SELECT 'multiplicity', %L,
        jsonb_build_object('orders_with_rows',count(*), 'orders_with_multiple_rows',count(*) FILTER(WHERE n>1),
          'max_rows_per_order', max(n), 'orders_without_rows',
          (SELECT count(*) FROM raw.orders o WHERE NOT EXISTS
           (SELECT FROM raw.%I c WHERE btrim(c.order_id)=btrim(o.order_id))))
      FROM (SELECT btrim(order_id), count(*) n FROM raw.%I GROUP BY btrim(order_id)) d
    $q$, t, t, t);
  END LOOP;
END $$;
INSERT INTO profile_result
SELECT 'review_grain', 'review_id', jsonb_build_object('duplicate_id_groups',count(*),
  'duplicate_id_excess_rows',coalesce(sum(n-1),0),'ids_on_multiple_orders',count(*) FILTER(WHERE orders>1))
FROM (SELECT btrim(review_id),count(*) n,count(DISTINCT btrim(order_id)) orders
      FROM raw.order_reviews GROUP BY btrim(review_id) HAVING count(*)>1) d;
INSERT INTO profile_result
SELECT 'customer_identity', 'customer_unique_id', jsonb_build_object('distinct_buyers',count(*),
  'buyers_with_multiple_customer_ids',count(*) FILTER(WHERE n>1),'max_customer_ids',max(n))
FROM (SELECT NULLIF(btrim(customer_unique_id),''), count(DISTINCT btrim(customer_id)) n
      FROM raw.customers GROUP BY NULLIF(btrim(customer_unique_id),'')) d;
-- Guard every cast: malformed source values must be counted, never abort the profile.
CREATE TEMP VIEW typed_orders AS
SELECT order_id, order_status,
  CASE WHEN pg_input_is_valid(order_purchase_timestamp,'timestamp') THEN order_purchase_timestamp::timestamp END purchased,
  CASE WHEN pg_input_is_valid(order_approved_at,'timestamp') THEN order_approved_at::timestamp END approved,
  CASE WHEN pg_input_is_valid(order_delivered_carrier_date,'timestamp') THEN order_delivered_carrier_date::timestamp END carrier,
  CASE WHEN pg_input_is_valid(order_delivered_customer_date,'timestamp') THEN order_delivered_customer_date::timestamp END delivered,
  CASE WHEN pg_input_is_valid(order_estimated_delivery_date,'timestamp') THEN order_estimated_delivery_date::timestamp END estimated
FROM raw.orders;
INSERT INTO profile_result
SELECT 'chronology','orders',jsonb_build_object('approved_before_purchase',count(*) FILTER(WHERE approved<purchased),
  'carrier_before_purchase',count(*) FILTER(WHERE carrier<purchased),
  'carrier_before_approval',count(*) FILTER(WHERE carrier<approved),
  'delivery_before_carrier',count(*) FILTER(WHERE delivered<carrier),
  'delivery_before_purchase',count(*) FILTER(WHERE delivered<purchased),
  'delivery_after_estimate',count(*) FILTER(WHERE delivered>estimated),
  'delivered_status_without_delivery_date',count(*) FILTER(WHERE order_status='delivered' AND delivered IS NULL))
FROM typed_orders;
INSERT INTO profile_result
SELECT 'purchase_month',to_char(date_trunc('month',purchased),'YYYY-MM'),jsonb_build_object('orders',count(*))
FROM typed_orders WHERE isfinite(purchased) GROUP BY date_trunc('month',purchased);
DO $$
DECLARE c record;
BEGIN
  FOR c IN SELECT * FROM (VALUES ('order_items','price'),('order_items','freight_value'),
    ('order_payments','payment_value'),('order_payments','payment_installments')) v(t,col) LOOP
    EXECUTE format($q$
      INSERT INTO profile_result SELECT 'numeric', %L,
        jsonb_build_object('sum_finite',sum(v) FILTER(WHERE lower(v::text) NOT IN ('nan','infinity','-infinity')),
          'zero_rows',count(*) FILTER(WHERE v=0),'negative_rows',count(*) FILTER(WHERE v<0))
      FROM (SELECT CASE WHEN pg_input_is_valid(NULLIF(btrim(%I),''),'numeric')
        THEN NULLIF(btrim(%I),'')::numeric END v FROM raw.%I) d
    $q$, c.t||'.'||c.col,c.col,c.col,c.t);
  END LOOP;
END $$;
SELECT jsonb_build_object('section',section,'subject',subject,'facts',facts)::text
FROM profile_result ORDER BY section,subject;
ROLLBACK;
