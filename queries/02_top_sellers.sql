-- Q2. Вся доступная история; доставленные заказы; только товары продавца.
WITH seller_totals AS (
    SELECT i.seller_id,
           COUNT(DISTINCT i.order_id) AS order_count,
           COUNT(*) AS units,
           SUM(i.price) AS revenue
    FROM core.order_items AS i
    JOIN core.orders AS o ON o.order_id = i.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY i.seller_id
)
SELECT t.seller_id, s.seller_city, s.seller_state,
       t.order_count, t.units, ROUND(t.revenue, 2) AS revenue
FROM seller_totals AS t
JOIN core.sellers AS s ON s.seller_id = t.seller_id
ORDER BY t.revenue DESC, t.seller_id
LIMIT 10;
