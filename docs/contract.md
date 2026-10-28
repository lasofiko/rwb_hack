# Контракт модели — v0, черновик A

Статус: черновик до фактов профилирования B. v1 фиксирует A по этим фактам,
дальше изменения только через A, предпочтительно совместимые добавления.
Колонки и типы — в `model/10_ddl.sql`, здесь — зерно, ключи и правила.

## Слои и сборка

- `raw` — как загрузил `setup.sh`, не меняется. Читают только B (ETL, профиль) и D (сверки).
- `core` — модель ниже. `mart` — витрины C. Ответы C читают только `core`/`mart`.
- `bash scripts/build.sh` → `model/build.sql`, одна транзакция:
  1. raw не пуст, иначе ошибка;
  2. `DROP/CREATE SCHEMA core, mart` — пересобираются только производные схемы;
  3. `model/10_ddl.sql` (A) — таблицы, ключи, индексы;
  4. `model/20_*.sql` (B) — загрузка core из raw, родители раньше детей;
  5. `mart/*.sql` (C) — витрины.

  Список файлов и порядок явно перечисляет `build.sql`, правит A: передайте путь и место в порядке.
- `bash scripts/check.sh` — проверки D после сборки, см. ниже.
- psql работает внутри контейнера, репозиторий смонтирован в `/work`, локальный psql не нужен.

## Правила для всех SQL-файлов

- Без `BEGIN/COMMIT`: транзакцией управляют build.sql и check.sh.
- Имена всегда со схемой: `core.orders`, `raw.orders`.
- Деньги — `numeric` без typmod (не округлять молча). Время — `timestamp` без часового пояса.
- Пустая строка и пробелы → NULL. NULL в core = «неизвестно»; метка `unknown` — только в mart и ответах.
- Строки не теряются: что не попало в core, лежит в `core.etl_rejects` с причиной.

## Таблицы core

| Таблица | Одна строка = | PK | FK | Источник |
|---|---|---|---|---|
| `customers` | покупатель-человек | `customer_unique_id` | — | distinct из `raw.customers` |
| `orders` | заказ + адрес этого заказа | `order_id`; `customer_id` UNIQUE | `customer_unique_id` | `raw.orders` + `raw.customers` по `customer_id` |
| `order_items` | единица товара одного продавца в заказе | `(order_id, order_item_id)` | `order_id`, `product_id`, `seller_id` | `raw.order_items` |
| `order_payments` | платёж заказа | `(order_id, payment_sequential)` | `order_id` | `raw.order_payments` |
| `order_reviews` | отзыв о заказе | `(review_id, order_id)` | `order_id` | `raw.order_reviews` |
| `products` | карточка товара | `product_id` | `product_category_name` (NULL = не указана) | `raw.products` |
| `sellers` | продавец | `seller_id` | — | `raw.sellers` |
| `categories` | категория (pt) | `product_category_name` | — | перевод + категории товаров без перевода |
| `calendar` | день | `day` | — | от 1-го числа месяца первого заказа до конца месяца последней даты в заказах |
| `etl_rejects` | отклонённая строка raw | — | — | все raw, с `reason` |

Решения v0:
- `customer_id` — это «покупатель в заказе» (1:1 с заказом), человек — `customer_unique_id`.
  Адрес остаётся в заказе, а не заменяется последним адресом покупателя.
- Категория без значения остаётся NULL в `products`; категория без перевода есть в `categories`
  с `product_category_name_english IS NULL`. Выдуманную категорию в core не добавляем.
- `order_estimated_delivery_date` — `date`: в источнике время всегда 00:00:00.
- Позиции, платежи и отзывы связаны только с заказом. Соединять их друг с другом можно только
  после агрегации до зерна заказа. Выручка продавца — его позиции, платёж — весь заказ.
- Опечатка `lenght` исправлена в core (`product_name_length`, `product_description_length`).

## Факты, проверенные A (узкий запрос, 28.10)

- Все кандидаты PK выше уникальны. Сирот нет ни по одной из 6 связей.
- `customer_id`: 99 441 = числу заказов; `customer_unique_id`: 96 096.
- Отзывы: `review_id` уникален в 98 410 из 99 224 строк, `order_id` — 98 673; пара уникальна.
- Товары без категории: 610. Категорий в товарах 73, из них 2 без перевода (в справочнике 71).
- `order_estimated_delivery_date`: строк не в 00:00:00 — 0.

## Что нужно от B (для v1)

- Форматы дат и чисел, scale денег, пустые строки, лишние пробелы и регистр в городах.
- Какие NULL реально есть: подтвердить или ослабить NOT NULL в `10_ddl.sql`.
- Статусы и даты: доставленные без даты вручения и т. п. Заказы без позиций и без платежей.
- Платежи: `payment_installments = 0`, `payment_type = 'not_defined'`, нулевые суммы.
- Повторы `(order_id, product_id, seller_id)` в позициях: это количество >1 одного товара.
- Список файлов `model/20_*.sql` и их порядок. `calendar` заполняет B после `orders`.

## Баланс для D

По каждой таблице: `count(raw) = count(core) + count(etl_rejects WHERE source_table = …)`.

| raw | core | Ожидание |
|---|---|---|
| `orders` | `orders` | 1:1 |
| `customers` | `orders` (по `customer_id`) | 1:1; `customers` = distinct `customer_unique_id` |
| `order_items`, `order_payments`, `order_reviews`, `products`, `sellers` | одноимённые | 1:1 |
| `product_category_translation` | `categories` | 71 + категории без перевода |

## Проверки (D)

- `checks/NN_name.sql` — обязательный инвариант. Нарушение → `RAISE EXCEPTION 'имя: детали'`.
- `checks/anomalies/NN_name.sql` — известная аномалия: `SELECT` с числом и ≤5 примерами, без исключений.
- Каждый файл — отдельный psql в транзакции с ROLLBACK: можно временные таблицы, база не меняется.

```sql
DO $$
DECLARE r bigint; c bigint; j bigint;
BEGIN
  SELECT count(*) INTO r FROM raw.orders;
  SELECT count(*) INTO c FROM core.orders;
  SELECT count(*) INTO j FROM core.etl_rejects WHERE source_table = 'orders';
  IF r <> c + j THEN
    RAISE EXCEPTION 'balance orders: raw % <> core % + rejects %', r, c, j;
  END IF;
END $$;
```
