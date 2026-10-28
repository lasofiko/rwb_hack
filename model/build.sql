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

-- 20: загрузка core из raw (B). Добавляются по готовности,
-- родительские таблицы раньше дочерних.
-- \ir 20_....sql

-- 30: витрины mart (C).
-- \ir ../mart/....sql

COMMIT;
