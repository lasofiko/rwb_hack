\set ON_ERROR_STOP on
\ir lib/assertions.sql

-- Верхняя граница по всем датам, включая обещанную доставку:
-- подтверждено пользователем 2026-10-28. Нижняя — месяц первой даты orders по v1.
DO $$
DECLARE first_day date; last_day date; missing_days bigint; extra_days bigint;
BEGIN
    SELECT date_trunc('month', least(min(order_purchase_timestamp), min(order_approved_at),
            min(order_delivered_carrier_date), min(order_delivered_customer_date),
            min(order_estimated_delivery_date)::timestamp))::date,
        (date_trunc('month', greatest(max(order_purchase_timestamp), max(order_approved_at),
            max(order_delivered_carrier_date), max(order_delivered_customer_date),
            max(order_estimated_delivery_date)::timestamp)) + interval '1 month' - interval '1 day')::date
    INTO first_day, last_day FROM core.orders;
    IF first_day IS NULL OR last_day IS NULL THEN
        RAISE EXCEPTION 'calendar bounds unavailable: core.orders empty';
    END IF;
    SELECT count(*) INTO missing_days FROM (
        SELECT d::date FROM generate_series(first_day::timestamp, last_day::timestamp, interval '1 day') AS axis(d)
        EXCEPT SELECT day FROM core.calendar
    ) missing;
    SELECT count(*) INTO extra_days FROM core.calendar WHERE day < first_day OR day > last_day;
    PERFORM pg_temp.assert_numeric('calendar missing days', missing_days, 0);
    PERFORM pg_temp.assert_numeric('calendar extra days', extra_days, 0);
    PERFORM pg_temp.assert_numeric('calendar exact row count',
        (SELECT count(*)::numeric FROM core.calendar), (last_day - first_day + 1)::numeric);
END;
$$;

SELECT pg_temp.assert_true('calendar attributes agree with day', NOT EXISTS (
    SELECT 1 FROM core.calendar WHERE day IS NULL
        OR month_start IS DISTINCT FROM date_trunc('month', day)::date
        OR year IS DISTINCT FROM extract(year FROM day)::smallint
        OR iso_dow IS DISTINCT FROM extract(isodow FROM day)::smallint
));

-- Не делаем один JOIN календарных дней к месячному агрегату: сначала месячная ось.
CREATE TEMP VIEW d_monthly_order_counts AS
WITH axis AS (SELECT DISTINCT month_start FROM core.calendar), facts AS (
    SELECT date_trunc('month', order_purchase_timestamp)::date month_start, count(*) n
    FROM core.orders GROUP BY 1
)
SELECT a.month_start, coalesce(f.n, 0) order_count FROM axis a LEFT JOIN facts f USING (month_start);
SELECT pg_temp.assert_numeric('monthly axis preserves calendar months',
    (SELECT count(*)::numeric FROM d_monthly_order_counts),
    (SELECT count(DISTINCT month_start)::numeric FROM core.calendar));
SELECT pg_temp.assert_numeric('monthly counts preserve orders and empty months',
    (SELECT sum(order_count) FROM d_monthly_order_counts), (SELECT count(*)::numeric FROM core.orders));
