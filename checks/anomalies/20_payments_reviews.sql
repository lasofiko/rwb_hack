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

-- Значимые исходные пробелы: только количество и ID, сами тексты не выводим.
WITH anomalies AS (
    SELECT 'review_title_edge_spaces' issue, review_id FROM core.order_reviews
    WHERE review_comment_title IS DISTINCT FROM btrim(review_comment_title)
    UNION ALL
    SELECT 'review_message_edge_spaces', review_id FROM core.order_reviews
    WHERE review_comment_message IS DISTINCT FROM btrim(review_comment_message)
), ranked AS (
    SELECT issue, review_id, row_number() OVER (PARTITION BY issue ORDER BY review_id) rn FROM anomalies
)
SELECT issue, count(*) row_count,
    array_agg(review_id ORDER BY review_id) FILTER (WHERE rn <= 5) example_review_ids
FROM ranked GROUP BY issue ORDER BY issue;

-- Повторный review_id допустим, не удалять через DISTINCT.
WITH ids AS (SELECT review_id, count(*) n FROM core.order_reviews GROUP BY review_id HAVING count(*) > 1),
ranked AS (SELECT *, row_number() OVER (ORDER BY review_id) rn FROM ids)
SELECT count(*) repeated_review_ids, coalesce(sum(n), 0) affected_rows,
    array_agg(review_id ORDER BY review_id) FILTER (WHERE rn <= 5) example_review_ids FROM ranked;

-- По профилю B payment_value не обязан равняться price + freight_value.
-- Это отчёт источников, не обязательный инвариант и не попытка исправить суммы.
WITH items AS (
    SELECT order_id, sum(price + freight_value) item_total FROM core.order_items GROUP BY order_id
), payments AS (
    SELECT order_id, sum(payment_value) payment_total FROM core.order_payments GROUP BY order_id
), classified AS (
    SELECT o.order_id, i.item_total, p.payment_total,
        CASE WHEN i.order_id IS NULL AND p.order_id IS NULL THEN 'no_items_no_payments'
             WHEN i.order_id IS NULL THEN 'payments_without_items'
             WHEN p.order_id IS NULL THEN 'items_without_payments'
             WHEN i.item_total = p.payment_total THEN 'both_equal'
             ELSE 'both_different' END issue
    FROM core.orders o LEFT JOIN items i USING (order_id) LEFT JOIN payments p USING (order_id)
), ranked AS (
    SELECT *, row_number() OVER (PARTITION BY issue ORDER BY order_id) rn FROM classified
)
SELECT issue, count(*) row_count, sum(item_total) item_total, sum(payment_total) payment_total,
    sum(payment_total - item_total) comparable_difference,
    count(*) FILTER (WHERE payment_total <> item_total AND abs(payment_total - item_total) <= 0.01) small_difference_rows,
    array_agg(order_id ORDER BY order_id) FILTER (WHERE rn <= 5) example_order_ids
FROM ranked GROUP BY issue ORDER BY issue;
