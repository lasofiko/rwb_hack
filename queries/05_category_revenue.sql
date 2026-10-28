-- Q5. Вся история, доставленные заказы; товарная выручка без доставки.
-- Группируем по исходному ключу: перевод или unknown — только подпись.
WITH category_totals AS (
    SELECT p.product_category_name, SUM(i.price) AS revenue
    FROM core.order_items AS i
    JOIN core.orders AS o ON o.order_id = i.order_id
    JOIN core.products AS p ON p.product_id = i.product_id
    WHERE o.order_status = 'delivered'
    GROUP BY p.product_category_name
)
SELECT t.product_category_name AS category_key,
       COALESCE(c.product_category_name_english,
                t.product_category_name, 'unknown') AS category,
       ROUND(t.revenue, 2) AS revenue,
       ROUND(100.0 * t.revenue / NULLIF(SUM(t.revenue) OVER (), 0), 2) AS revenue_pct
FROM category_totals AS t
LEFT JOIN core.categories AS c USING (product_category_name)
ORDER BY t.revenue DESC, t.product_category_name NULLS LAST;
