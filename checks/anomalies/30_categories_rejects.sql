SELECT 'products_without_category' issue, count(*) rows FROM core.products WHERE product_category_name IS NULL
UNION ALL SELECT 'categories_without_translation', count(*) FROM core.categories
WHERE product_category_name_english IS NULL;

SELECT source_table, reason, count(*) rows FROM core.etl_rejects GROUP BY source_table, reason ORDER BY 1, 2;

WITH unknowns AS (
    SELECT product_id, product_category_name FROM core.products WHERE product_category_name IS NULL
    UNION ALL
    SELECT p.product_id, p.product_category_name FROM core.products p
    JOIN core.categories c USING (product_category_name) WHERE c.product_category_name_english IS NULL
), ranked AS (
    SELECT *, row_number() OVER (PARTITION BY (product_category_name IS NULL) ORDER BY product_id) rn FROM unknowns
)
SELECT product_id, product_category_name FROM ranked WHERE rn <= 5
ORDER BY (product_category_name IS NULL), product_id;
