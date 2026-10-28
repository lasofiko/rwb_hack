-- B: raw -> core, docs/contract.md v1 / model/10_ddl.sql.
-- Run once into empty core inside the transaction owned by model/build.sql.
-- No BEGIN/COMMIT, no raw writes. Reject all conflicting keys, never choose a winner.
SET LOCAL datestyle = 'ISO, YMD';
CREATE TEMP TABLE _b_stage (
    source_table text NOT NULL,
    source_key text,
    key_value text,
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
-- Text is preserved verbatim, including empty strings and whitespace-only reviews.
CREATE FUNCTION pg_temp.b_normalize(payload jsonb, fields jsonb)
RETURNS TABLE(data jsonb, reasons text[]) LANGUAGE plpgsql AS $$
DECLARE f jsonb; v text; col text; typ text; valid boolean;
BEGIN
 data := '{}'::jsonb; reasons := ARRAY[]::text[];
 FOR f IN SELECT value FROM jsonb_array_elements(fields) LOOP
   col := f->>'core_name'; typ := f->>'type';
   v := payload->>(f->>'raw_name');
   IF typ <> 'text' THEN v := NULLIF(v,''); END IF;
   -- Literal type names keep each input validator tied to one concrete type.
   valid := CASE typ
     WHEN 'text' THEN true
     WHEN 'integer' THEN pg_input_is_valid(v,'integer')
     WHEN 'smallint' THEN pg_input_is_valid(v,'smallint')
     WHEN 'numeric' THEN pg_input_is_valid(v,'numeric')
     WHEN 'timestamp without time zone' THEN pg_input_is_valid(v,'timestamp without time zone')
     WHEN 'date' THEN pg_input_is_valid(v,'date')
     ELSE false END;
   IF v IS NULL OR ((f->>'required')::boolean AND v='') THEN
     IF (f->>'required')::boolean THEN
       reasons := array_append(reasons,CASE WHEN (f->>'key')::boolean THEN 'null_key:' ELSE 'null_required:' END||col);
     END IF;
   ELSIF valid IS NOT TRUE THEN
     reasons := array_append(reasons,'bad_type:'||col);
   ELSE
     IF typ IN ('numeric','timestamp without time zone','date') AND
        lower(v) IN ('nan','+nan','-nan','infinity','+infinity','-infinity','inf','+inf','-inf') THEN
       reasons := array_append(reasons,'invalid_value:'||col);
     ELSIF col IN ('order_item_id','payment_sequential') THEN
       v := (v::integer)::text; -- canonical keys: '01' conflicts with '1'
     ELSIF col IN ('price','freight_value','payment_value') THEN
       IF v::numeric < 0 THEN
         reasons := array_append(reasons,'invalid_value:'||col);
       END IF;
     ELSIF col='payment_installments' THEN
       IF v::integer < 0 THEN
         reasons := array_append(reasons,'invalid_value:payment_installments');
       END IF;
     ELSIF col='review_score' THEN
       IF v::smallint NOT BETWEEN 1 AND 5 THEN
         reasons := array_append(reasons,'invalid_value:review_score');
       END IF;
     ELSIF col='order_estimated_delivery_date' THEN
       IF NOT pg_input_is_valid(v,'timestamp without time zone') THEN
         reasons := array_append(reasons,'bad_type:'||col);
       ELSIF v::timestamp::time <> time '00:00:00' THEN
         reasons := array_append(reasons,'invalid_value:'||col);
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
       'key',r.column_name=ANY(s.keys) OR (s.name='customers' AND r.column_name='customer_unique_id'),
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
   UPDATE pg_temp._b_stage st SET key_value=(
       SELECT jsonb_agg(st.data->k ORDER BY ord)::text
       FROM unnest(s.keys) WITH ORDINALITY x(k,ord))
   WHERE st.source_table=s.name;
   UPDATE pg_temp._b_stage st SET source_key=(
       SELECT string_agg(coalesce(st.payload->>k,''),'|' ORDER BY ord)
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
   FROM (SELECT key_value FROM pg_temp._b_stage WHERE source_table=s.name
         GROUP BY key_value HAVING count(*)>1) d
   WHERE st.source_table=s.name AND st.key_value=d.key_value;
 END LOOP;
 -- core.orders also requires customer_id UNIQUE.
 UPDATE pg_temp._b_stage st SET reasons=array_append(st.reasons,'duplicate_key')
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
