WITH anomalies AS (
    SELECT 'zero_installments' issue, order_id FROM core.order_payments WHERE payment_installments = 0
    UNION ALL SELECT 'not_defined_payment_type', order_id FROM core.order_payments WHERE payment_type = 'not_defined'
    UNION ALL SELECT 'zero_payment', order_id FROM core.order_payments WHERE payment_value = 0
    UNION ALL SELECT 'multiple_payments', order_id FROM core.order_payments GROUP BY order_id HAVING count(*) > 1
    UNION ALL SELECT 'multiple_reviews', order_id FROM core.order_reviews GROUP BY order_id HAVING count(*) > 1
), ranked AS (
    SELECT issue, order_id, row_number() OVER (PARTITION BY issue ORDER BY order_id) rn FROM anomalies
)
SELECT issue, count(*) rows,
    array_agg(order_id ORDER BY order_id) FILTER (WHERE rn <= 5) example_order_ids
FROM ranked GROUP BY issue ORDER BY issue;

-- Повторный review_id допустим, не удалять через DISTINCT.
WITH ids AS (SELECT review_id, count(*) n FROM core.order_reviews GROUP BY review_id HAVING count(*) > 1),
ranked AS (SELECT *, row_number() OVER (ORDER BY review_id) rn FROM ids)
SELECT count(*) repeated_review_ids, coalesce(sum(n), 0) affected_rows,
    array_agg(review_id ORDER BY review_id) FILTER (WHERE rn <= 5) example_review_ids FROM ranked;
