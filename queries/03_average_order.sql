-- Q3. Доставленные заказы, вся история; чек включает доставку.
-- Отсутствие позиций делает средние неизвестными, а не нулевыми.
WITH order_totals AS (
    SELECT order_id, SUM(price + freight_value) AS order_value,
           COUNT(*) AS item_count
    FROM core.order_items
    GROUP BY order_id
)
SELECT CASE WHEN COUNT(*) = COUNT(t.order_id)
            THEN ROUND(AVG(t.order_value), 2) END AS avg_order_value,
       CASE WHEN COUNT(*) = COUNT(t.order_id)
            THEN ROUND(AVG(t.item_count), 3) END AS avg_rows_per_order,
       CASE WHEN COUNT(*) = COUNT(t.order_id)
            THEN ROUND(AVG(t.item_count), 3) END AS avg_units_per_order,
       COUNT(*) AS order_count,
       COUNT(*) - COUNT(t.order_id) AS orders_without_items
FROM core.orders AS o
LEFT JOIN order_totals AS t ON t.order_id = o.order_id
WHERE o.order_status = 'delivered';
