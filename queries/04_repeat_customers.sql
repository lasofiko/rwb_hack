-- Q4. Покупатели хотя бы с одним заказом; вся история и все статусы.
-- Повторное оформление заказа отличается от повторной успешной покупки.
WITH customer_orders AS (
    SELECT customer_unique_id, COUNT(*) AS order_count
    FROM core.orders
    GROUP BY customer_unique_id
)
SELECT COUNT(*) AS customers,
       COUNT(*) FILTER (WHERE order_count >= 2) AS repeat_customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_count >= 2)
             / NULLIF(COUNT(*), 0), 2) AS repeat_pct
FROM customer_orders;
