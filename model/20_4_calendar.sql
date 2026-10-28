-- B / contract v1: calendar and mandatory conservation checks.
-- First month -> last month of every known order date, inclusive.
WITH bounds AS (
 SELECT date_trunc('month',min(least(order_purchase_timestamp,order_approved_at,
          order_delivered_carrier_date,order_delivered_customer_date,
          order_estimated_delivery_date::timestamp))) first_day,
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
