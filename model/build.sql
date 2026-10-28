-- Сборка модели из raw. Запуск: bash scripts/build.sh
--
-- Порядок файлов — явный, список правит только A (см. docs/contract.md).
-- Подключаемые файлы не содержат BEGIN/COMMIT: вся сборка — одна
-- транзакция, при ошибке core и mart откатываются к прежнему состоянию.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

-- Строим только из штатно загруженного raw (bash scripts/setup.sh).
DO $$
DECLARE
    t  text;
    ok boolean;
BEGIN
    FOREACH t IN ARRAY ARRAY['orders', 'order_items', 'order_payments',
                             'order_reviews', 'products', 'sellers',
                             'customers', 'product_category_translation']
    LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM raw.%I)', t) INTO ok;
        IF NOT ok THEN
            RAISE EXCEPTION 'raw.% пуст: сначала bash scripts/setup.sh', t;
        END IF;
    END LOOP;
END $$;

-- Пересобираем только производные схемы, raw не трогаем.
DROP SCHEMA IF EXISTS mart CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA core;
CREATE SCHEMA mart;

\echo '    10 ddl'
\ir 10_ddl.sql

-- 20: загрузка core из raw (B), порядок из docs/contract.md: родители раньше детей.
-- 20_4 в конце сверяет баланс raw = core + rejects и падает, если не сходится.
\echo '    20_1 dims'
\ir 20_1_dims.sql
\echo '    20_2 orders'
\ir 20_2_orders.sql
\echo '    20_3 order children'
\ir 20_3_order_children.sql
\echo '    20_4 calendar + balance'
\ir 20_4_calendar.sql

-- 30: витрины mart (C).
-- \ir ../mart/....sql

COMMIT;
