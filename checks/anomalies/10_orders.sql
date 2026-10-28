-- Диагностика источника/бизнеса; не ошибки модели и не ограничения хронологии.
WITH anomalies AS (
    SELECT 'delivered_without_delivery_date' issue, order_id FROM core.orders
    WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL
    UNION ALL SELECT 'orders_without_items', o.order_id FROM core.orders o
    WHERE NOT EXISTS (SELECT 1 FROM core.order_items i WHERE i.order_id = o.order_id)
    UNION ALL SELECT 'orders_without_payments', o.order_id FROM core.orders o
    WHERE NOT EXISTS (SELECT 1 FROM core.order_payments p WHERE p.order_id = o.order_id)
    UNION ALL SELECT 'approval_before_purchase', order_id FROM core.orders
    WHERE order_approved_at < order_purchase_timestamp
    UNION ALL SELECT 'delivery_before_carrier', order_id FROM core.orders
    WHERE order_delivered_customer_date < order_delivered_carrier_date
), ranked AS (
    SELECT issue, order_id, row_number() OVER (PARTITION BY issue ORDER BY order_id) rn
    FROM anomalies
)
SELECT issue, count(*) rows,
    array_agg(order_id ORDER BY order_id) FILTER (WHERE rn <= 5) example_order_ids
FROM ranked GROUP BY issue ORDER BY issue;
