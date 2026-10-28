-- Q1. Месяц оформления; доставленные заказы; товарная выручка без доставки.
-- Сначала одна строка суммы на заказ: позиции не размножают число заказов.
WITH months AS (
    SELECT DISTINCT month_start
    FROM core.calendar
    WHERE month_start >= DATE '2016-09-01'
      AND month_start < DATE '2018-09-01'
), revenue_per_order AS (
    SELECT order_id, SUM(price) AS revenue
    FROM core.order_items
    GROUP BY order_id
), monthly AS (
    SELECT DATE_TRUNC('month', o.order_purchase_timestamp)::date AS month_start,
           COUNT(*) AS order_count,
           SUM(r.revenue) AS revenue
    FROM core.orders AS o
    LEFT JOIN revenue_per_order AS r ON r.order_id = o.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= TIMESTAMP '2016-09-01'
      AND o.order_purchase_timestamp < TIMESTAMP '2018-09-01'
    GROUP BY 1
)
SELECT m.month_start AS month,
       COALESCE(s.order_count, 0) AS order_count,
       ROUND(COALESCE(s.revenue, 0), 2) AS revenue
FROM months AS m
LEFT JOIN monthly AS s ON s.month_start = m.month_start
ORDER BY m.month_start;
