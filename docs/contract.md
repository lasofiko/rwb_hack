# Контракт модели — v1

Статус: **v1.1 от 28.10**: v1 по профилю B (`docs/data-quality.md`), уточнён
по фактической загрузке B `model/20_load_core.sql` (PR #9).
Совместим с запросами C `queries/0*.sql` и метриками `docs/metrics.md` v0.
Дальше изменения только через A, предпочтительно совместимые добавления.
Колонки и типы — в `model/10_ddl.sql`, здесь — зерно, ключи и правила.

## Слои и сборка

- `raw` — как загрузил `setup.sh`, не меняется. Читают только B (ETL, профиль) и D (сверки).
- `core` — модель ниже. `mart` — витрины C. Ответы C читают только `core`/`mart`.
- `bash scripts/build.sh` → `model/build.sql`, одна транзакция:
  1. raw не пуст, иначе ошибка;
  2. `DROP/CREATE SCHEMA core, mart` — пересобираются только производные схемы;
  3. `model/10_ddl.sql` (A) — таблицы, ключи, индексы;
  4. `model/20_load_core.sql` (B) — загрузка core из raw одним файлом:
     customers, sellers, categories, products → orders → items, payments, reviews →
     rejects → calendar → собственная проверка баланса (ошибка, если не сходится);
  5. `mart/*.sql` (C) — витрины.

  Список и порядок файлов явно перечисляет `build.sql`, правит A.
  Новый файл или другое разбиение — сообщите A, порядок «родители раньше детей» обязателен.
- `bash scripts/check.sh` — проверки D после сборки, см. ниже.
- psql работает внутри контейнера, репозиторий смонтирован в `/work`, локальный psql не нужен.

## Правила для всех SQL-файлов

- Без `BEGIN/COMMIT`: транзакцией управляют build.sql и check.sh.
- Имена всегда со схемой: `core.orders`, `raw.orders`. Явные списки колонок в `INSERT`.
- Тексты: `NULLIF(btrim(x), '')` — пустая или пробельная строка = NULL, без `lower` и `DISTINCT`.
  Непустой текст отзыва переносится байт в байт, вместе с пробелами по краям.
  В снимке `btrim` вне отзывов не меняет ни одного значения.
- Типизированные колонки: то же, затем проверка `pg_input_is_valid(x, '<тип>')`
  и приведение. Деньги — `numeric` без typmod, время — `timestamp` без часового пояса.
- NULL в core = «неизвестно». Ноль, `unknown`, единица рассрочки вместо NULL/0 не подставляются.

## Политика плохих строк

Строка raw, которая не может попасть в core, кладётся в `core.etl_rejects`, сборка продолжается:

Коды — как в `model/20_load_core.sql`:

| reason | Когда |
|---|---|
| `missing_required:<колонка>` | пусто в ключе или в колонке `NOT NULL` |
| `bad_type:<колонка>` | `pg_input_is_valid` = false |
| `nonfinite:<колонка>` | `NaN` / `Infinity` в деньгах или датах |
| `negative_money:<колонка>`, `out_of_range:review_score` | нарушает `CHECK` |
| `non_midnight:order_estimated_delivery_date` | у обещанной даты есть время — колонка `date` его потеряла бы |
| `duplicate_key` | у ключа несколько строк — отклоняются **все**, без выбора «правильной» |
| `duplicate_customer_id` | один `customer_id` у нескольких заказов |
| `orphan_fk:<таблица>` | нет родителя в core, в том числе потому, что родитель сам отклонён |
| `unreferenced_customer` | запись `raw.customers` не связана ни с одним принятым заказом |

Несколько причин у строки — через `;`. `source_key` — JSON-массив значений ключа
(`["<order_id>","1"]`), `payload` — `to_jsonb(r)`.
Сборка падает только на ошибке SQL или нарушении ограничения core — это баг ETL, а не данных.
Для текущего снимка профиль B ожидает **0** отклонённых строк.

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
| `calendar` | день | `day` | — | от 1-го числа месяца первой даты в orders до конца месяца последней |
| `etl_rejects` | отклонённая строка raw | — | — | все raw, с `reason` |

## Решения v1

- **Покупатель.** Человек — `customer_unique_id`. `customer_id` — «покупатель в заказе»,
  1:1 с заказом, хранится в `orders`. Адрес — тот, что был в заказе, а не последний.
- **Дочерние наборы необязательны.** Заказ без позиций (775), без платежа (1),
  без отзыва (768) остаётся в `orders`. Загрузка заказов не зависит от детей.
- **Позиции, платежи, отзывы** связаны только с заказом. Соединять друг с другом —
  только после агрегации до зерна заказа. Выручка продавца — его позиции, платёж — весь заказ.
- **Категории.** NULL-категория остаётся NULL в `products` (610 товаров). Строки `unknown`
  в core нет: метку даёт mart/ответ через `COALESCE`. Категории без перевода
  (`pc_gamer`, `portateis_cozinha_e_preparadores_de_alimentos`) есть в `categories`
  с `product_category_name_english IS NULL` — это и есть признак отсутствия перевода.
- **ZIP** — как в источнике (4–5 цифр). Дополнение нулём — вывод, а не факт источника;
  если понадобится, добавим отдельную колонку совместимо.
- **Тексты отзывов** — непустые байт в байт, включая пробелы по краям. Пробельные
  (2 заголовка, 9 сообщений) — NULL, то есть «комментария нет»; оригинал остаётся в raw.
- **Даты** — без перестановки и коррекции, включая 8 delivered без даты вручения
  и нарушения порядка этапов. Это аномалии для D, а не ошибки загрузки.
- **Платежи** — `payment_installments = 0` и `payment_type = 'not_defined'` как есть;
  9 нулевых платежей допустимы (`CHECK >= 0`).
- `order_estimated_delivery_date` — `date`: время в источнике всегда 00:00:00.
- Опечатка `lenght` исправлена в core (`product_name_length`, `product_description_length`).

## Что B сверяет после загрузки

| core | Строк | Суммы и прочее |
|---|---:|---|
| `customers` | 96 096 | — |
| `orders` | 99 441 | `customer_id` 99 441 |
| `order_items` | 112 650 | price **13 591 643.70**, freight **2 256 599.44** |
| `order_payments` | 103 886 | payment_value **16 008 872.12** |
| `order_reviews` | 99 224 | — |
| `products` | 32 951 | NULL-категория 610 |
| `sellers` | 3 095 | — |
| `categories` | 73 | без перевода 2 |
| `calendar` | 821 | 2016-09-01 … 2018-11-30, 27 месяцев |
| `etl_rejects` | 0 | — |

Сверено A при интеграции (28.10, `build.sh` за ~18 с): все числа совпали.
Повторная сборка на том же raw — отпечатки (md5 строк по PK) 9 таблиц core одинаковые.
Контроли Q1–Q5 на запросах C сошлись.

## Баланс для D

По каждой таблице: `count(raw) = count(core) + count(etl_rejects WHERE source_table = …)`.

| raw | core | Ожидание |
|---|---|---|
| `orders` | `orders` | 1:1 |
| `customers` | `orders` (по `customer_id`) | 1:1; `customers` = distinct `customer_unique_id` |
| `order_items`, `order_payments`, `order_reviews`, `products`, `sellers` | одноимённые | 1:1 |
| `product_category_translation` | `categories` | 71 + категории без перевода |

Суммы денег raw и core совпадают точно (с учётом отклонённых строк).

## Проверки (D)

- `checks/NN_name.sql` — обязательный инвариант. Нарушение → `RAISE EXCEPTION 'имя: детали'`.
- `checks/anomalies/NN_name.sql` — известная аномалия: `SELECT` с числом и ≤5 примерами, без исключений.
  Сюда же — `etl_rejects` по `reason` и аномалии дат из профиля B.
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

## Изменения v1 → v1.1

- Загрузка B — один файл `20_load_core.sql` вместо четырёх.
- Коды `reason` и формат `source_key` — как реализовал B.
- Тексты: пробельная строка = NULL (v1: байт в байт). Меняет 11 значений в отзывах.
  Принято A: пробелы не несут содержания, аналитику не нужно помнить про `btrim`.
- Таблицы и колонки не менялись.

## Изменения v0 → v1

- Политика плохих строк и коды `reason`; имена и порядок файлов B.
- Тексты без trim (вместо «пробелы → NULL» в v0), ZIP без дополнения.
- `CHECK (payment_installments >= 0)`; комментарии в DDL. Таблицы и колонки не менялись.
- Ожидаемые числа для сверки B.
