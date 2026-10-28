-- B: raw -> core, docs/contract.md v0 / model/10_ddl.sql.
-- Run once into empty core inside the transaction owned by model/build.sql.
-- No BEGIN/COMMIT, no raw writes. Reject all conflicting keys, never choose a winner.
SET LOCAL datestyle = 'ISO, YMD';
CREATE TEMP TABLE _b_stage (
    source_table text NOT NULL,
    source_key text,
    data jsonb NOT NULL,
    payload jsonb NOT NULL,
    reasons text[] NOT NULL
) ON COMMIT DROP;
CREATE INDEX ON _b_stage(source_table);
CREATE TEMP TABLE _b_sources (name text PRIMARY KEY, target text, keys text[]) ON COMMIT DROP;
INSERT INTO _b_sources VALUES
 ('customers','customers',ARRAY['customer_id']),
 ('sellers','sellers',ARRAY['seller_id']),
 ('product_category_translation','categories',ARRAY['product_category_name']),
 ('products','products',ARRAY['product_id']),
 ('orders','orders',ARRAY['order_id']),
 ('order_items','order_items',ARRAY['order_id','order_item_id']),
 ('order_payments','order_payments',ARRAY['order_id','payment_sequential']),
 ('order_reviews','order_reviews',ARRAY['review_id','order_id']);

-- Metadata comes from A's core DDL; special raw names are mapped explicitly below.
-- Keep nonblank review prose verbatim; a wholly blank string becomes NULL.
CREATE FUNCTION pg_temp.b_normalize(payload jsonb, fields jsonb)
RETURNS TABLE(data jsonb, reasons text[]) LANGUAGE plpgsql AS $$
DECLARE f jsonb; v text; col text; typ text; valid boolean;
BEGIN
 data := '{}'::jsonb; reasons := ARRAY[]::text[];
 FOR f IN SELECT value FROM jsonb_array_elements(fields) LOOP
   col := f->>'core_name'; typ := f->>'type';
   v := NULLIF(btrim(payload->>(f->>'raw_name')),'');
   IF v IS NOT NULL AND col IN ('review_comment_title','review_comment_message') THEN
     v := payload->>(f->>'raw_name');
   END IF;
   -- Literal type names keep each input validator tied to one concrete type.
   valid := CASE typ
     WHEN 'text' THEN true
     WHEN 'integer' THEN pg_input_is_valid(v,'integer')
     WHEN 'smallint' THEN pg_input_is_valid(v,'smallint')
     WHEN 'numeric' THEN pg_input_is_valid(v,'numeric')
     WHEN 'timestamp without time zone' THEN pg_input_is_valid(v,'timestamp without time zone')
     WHEN 'date' THEN pg_input_is_valid(v,'date')
     ELSE false END;
   IF v IS NULL THEN
     IF (f->>'required')::boolean THEN
       reasons := array_append(reasons,'missing_required:'||col);
     END IF;
   ELSIF valid IS NOT TRUE THEN
     reasons := array_append(reasons,'bad_type:'||col);
   ELSE
     IF typ IN ('numeric','timestamp without time zone','date') AND
        lower(v) IN ('nan','infinity','-infinity') THEN
       reasons := array_append(reasons,'nonfinite:'||col);
     ELSIF col IN ('order_item_id','payment_sequential') THEN
       v := (v::integer)::text; -- canonical keys: '01' conflicts with '1'
     ELSIF col IN ('price','freight_value','payment_value') THEN
       IF v::numeric < 0 THEN
         reasons := array_append(reasons,'negative_money:'||col);
       END IF;
     ELSIF col='review_score' THEN
       IF v::smallint NOT BETWEEN 1 AND 5 THEN
         reasons := array_append(reasons,'out_of_range:review_score');
       END IF;
     ELSIF col='order_estimated_delivery_date' THEN
       IF NOT pg_input_is_valid(v,'timestamp without time zone') THEN
         reasons := array_append(reasons,'bad_type:'||col);
       ELSIF v::timestamp::time <> time '00:00:00' THEN
         reasons := array_append(reasons,'non_midnight:'||col);
       END IF;
     END IF;
   END IF;
   data := data || jsonb_build_object(col,v);
 END LOOP;
 RETURN NEXT;
END $$;

DO $$
DECLARE s record; fields jsonb;
BEGIN
 IF current_setting('server_version_num')::integer < 160000 THEN
   RAISE EXCEPTION 'B ETL requires PostgreSQL 16+';
 END IF;
 FOR s IN SELECT * FROM pg_temp._b_sources ORDER BY name LOOP
   SELECT jsonb_agg(jsonb_build_object('raw_name',r.column_name,
       'core_name',m.core_name,'type',coalesce(format_type(a.atttypid,a.atttypmod),'text'),
       'required',coalesce(a.attnotnull,false) OR
         (s.name='customers' AND r.column_name IN ('customer_id','customer_unique_id')))
       ORDER BY r.ordinal_position)
   INTO fields
   FROM information_schema.columns r
   CROSS JOIN LATERAL (SELECT CASE r.column_name
       WHEN 'product_name_lenght' THEN 'product_name_length'
       WHEN 'product_description_lenght' THEN 'product_description_length'
       ELSE r.column_name END core_name) m
   LEFT JOIN pg_catalog.pg_attribute a ON
       a.attrelid=to_regclass('core.'||s.target) AND a.attname=m.core_name
       AND a.attnum>0 AND NOT a.attisdropped
   WHERE r.table_schema='raw' AND r.table_name=s.name
     AND r.column_name NOT IN ('_source_file','_loaded_at');
   IF fields IS NULL THEN RAISE EXCEPTION 'Missing raw.%',s.name; END IF;
   EXECUTE format($q$
     INSERT INTO pg_temp._b_stage(source_table,data,payload,reasons)
     SELECT %L,n.data,to_jsonb(r),n.reasons FROM raw.%I r
     CROSS JOIN LATERAL pg_temp.b_normalize(to_jsonb(r),$1) n
   $q$,s.name,s.name) USING fields;
   UPDATE pg_temp._b_stage st SET source_key=(
       SELECT jsonb_agg(st.data->k ORDER BY ord)::text
       FROM unnest(s.keys) WITH ORDINALITY x(k,ord))
   WHERE st.source_table=s.name;
 END LOOP;
END $$;
-- Every source row is staged separately, even when its payload is identical.
-- Natural-key duplicates include bad rows so no valid-looking sibling wins silently.
DO $$
DECLARE s record;
BEGIN
 FOR s IN SELECT * FROM pg_temp._b_sources LOOP
   UPDATE pg_temp._b_stage st SET reasons=array_append(st.reasons,'duplicate_key')
   FROM (SELECT source_key FROM pg_temp._b_stage WHERE source_table=s.name
         GROUP BY source_key HAVING count(*)>1) d
   WHERE st.source_table=s.name AND st.source_key=d.source_key;
 END LOOP;
 -- core.orders also requires customer_id UNIQUE.
 UPDATE pg_temp._b_stage st SET reasons=array_append(st.reasons,'duplicate_customer_id')
 FROM (SELECT data->>'customer_id' k FROM pg_temp._b_stage WHERE source_table='orders'
       AND data->>'customer_id' IS NOT NULL
       GROUP BY data->>'customer_id' HAVING count(*)>1) d
 WHERE st.source_table='orders' AND st.data->>'customer_id'=d.k;
END $$;

-- DISTINCT here implements the explicit person grain, not source deduplication.
INSERT INTO core.customers(customer_unique_id)
SELECT DISTINCT data->>'customer_unique_id' FROM pg_temp._b_stage
WHERE source_table='customers' AND cardinality(reasons)=0;
INSERT INTO core.sellers(seller_id,seller_zip_code_prefix,seller_city,seller_state)
SELECT r.seller_id,r.seller_zip_code_prefix,r.seller_city,r.seller_state
FROM pg_temp._b_stage s CROSS JOIN LATERAL jsonb_populate_record(NULL::core.sellers,CASE WHEN s.source_table='sellers' AND cardinality(s.reasons)=0 THEN s.data ELSE '{}'::jsonb END) r
WHERE s.source_table='sellers' AND cardinality(s.reasons)=0;

-- Preserve categories without translation and NULL categories on products.
INSERT INTO core.categories(product_category_name,product_category_name_english)
SELECT data->>'product_category_name',data->>'product_category_name_english'
FROM pg_temp._b_stage WHERE source_table='product_category_translation' AND cardinality(reasons)=0;
INSERT INTO core.categories(product_category_name,product_category_name_english)
SELECT DISTINCT s.data->>'product_category_name',NULL
FROM pg_temp._b_stage s WHERE s.source_table='products' AND cardinality(s.reasons)=0
AND s.data->>'product_category_name' IS NOT NULL
AND NOT EXISTS (SELECT FROM core.categories c WHERE c.product_category_name=s.data->>'product_category_name');
INSERT INTO core.products(product_id,product_category_name,product_name_length,product_description_length,
    product_photos_qty,product_weight_g,product_length_cm,product_height_cm,product_width_cm)
SELECT r.product_id,r.product_category_name,r.product_name_length,r.product_description_length,
    r.product_photos_qty,r.product_weight_g,r.product_length_cm,r.product_height_cm,r.product_width_cm
FROM pg_temp._b_stage s CROSS JOIN LATERAL jsonb_populate_record(NULL::core.products,CASE WHEN s.source_table='products' AND cardinality(s.reasons)=0 THEN s.data ELSE '{}'::jsonb END) r
WHERE s.source_table='products' AND cardinality(s.reasons)=0;

-- Unique, valid raw customer records are the order's address, never the latest address of a person.
CREATE TEMP TABLE _b_customer ON COMMIT DROP AS
SELECT data->>'customer_id' customer_id,data FROM pg_temp._b_stage
WHERE source_table='customers' AND cardinality(reasons)=0;
CREATE UNIQUE INDEX ON _b_customer(customer_id);
UPDATE pg_temp._b_stage s SET reasons=array_append(s.reasons,'orphan_fk:customers')
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
UPDATE pg_temp._b_stage s SET reasons=array_append(s.reasons,'unreferenced_customer')
WHERE s.source_table='customers' AND cardinality(s.reasons)=0
AND NOT EXISTS (SELECT FROM core.orders o WHERE o.customer_id=s.data->>'customer_id');
DELETE FROM core.customers c WHERE NOT EXISTS
 (SELECT FROM core.orders o WHERE o.customer_unique_id=c.customer_unique_id);

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
   $q$,'orphan_fk:'||f.parent,f.child,f.parent,f.parent_col,f.col);
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
SELECT source_table,source_key,array_to_string(reasons,';'),payload FROM pg_temp._b_stage
WHERE cardinality(reasons)>0;

-- First purchase month -> last month of every known order date, inclusive.
WITH bounds AS (
 SELECT date_trunc('month',min(order_purchase_timestamp)) first_day,
        date_trunc('month',max(greatest(order_purchase_timestamp,order_approved_at,
          order_delivered_carrier_date,order_delivered_customer_date,
          order_estimated_delivery_date::timestamp))) + interval '1 month - 1 day' last_day
 FROM core.orders
)
INSERT INTO core.calendar(day,month_start,year,iso_dow)
SELECT d::date,date_trunc('month',d)::date,extract(year FROM d)::smallint,extract(isodow FROM d)::smallint
FROM bounds CROSS JOIN LATERAL generate_series(first_day,last_day,interval '1 day') d;

-- Conservation is mandatory, including the contract's two grain transformations.
DO $$
DECLARE s record; raw_n bigint; loaded_n bigint; reject_n bigint;
BEGIN
 FOR s IN SELECT * FROM pg_temp._b_sources LOOP
   EXECUTE format('SELECT count(*) FROM raw.%I',s.name) INTO raw_n;
   SELECT count(*) INTO reject_n FROM core.etl_rejects WHERE source_table=s.name;
   IF s.name='customers' THEN
     SELECT count(*) INTO loaded_n FROM core.orders;
   ELSIF s.name='product_category_translation' THEN
     SELECT count(*) INTO loaded_n FROM pg_temp._b_stage st JOIN core.categories c
       ON c.product_category_name=st.data->>'product_category_name'
       AND c.product_category_name_english IS NOT DISTINCT FROM st.data->>'product_category_name_english'
       WHERE st.source_table=s.name AND cardinality(st.reasons)=0;
   ELSE
     EXECUTE format('SELECT count(*) FROM core.%I',s.target) INTO loaded_n;
   END IF;
   IF raw_n<>loaded_n+reject_n THEN
     RAISE EXCEPTION 'B balance %: raw % <> loaded % + rejects %',s.name,raw_n,loaded_n,reject_n;
   END IF;
 END LOOP;
END $$;
