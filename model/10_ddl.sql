-- core: структура модели, черновик v0 по docs/contract.md.
-- Только таблицы, ключи, ограничения и индексы. Наполнение — model/20_*.sql (B).
-- Схему core создаёт model/build.sql.
--
-- Имена колонок как в raw (кроме опечатки lenght в products), типы — настоящие.
-- Деньги numeric без typmod: не округлять молча. Время — timestamp без пояса,
-- как в источнике. NULL = «неизвестно»; метка unknown появляется только в mart.

-- Покупатель-человек. В raw.customers одна строка на заказ (customer_id),
-- поэтому человек — это customer_unique_id. Адрес хранится в заказе.
CREATE TABLE core.customers (
    customer_unique_id text PRIMARY KEY
);

-- Продавец.
CREATE TABLE core.sellers (
    seller_id              text PRIMARY KEY,
    seller_zip_code_prefix text,  -- text: ведущие нули значимы
    seller_city            text,
    seller_state           text
);

-- Категория товара. Строки = справочник перевода + категории из products
-- без перевода (у них category_name_english IS NULL).
CREATE TABLE core.categories (
    product_category_name         text PRIMARY KEY,  -- португальское имя
    product_category_name_english text
);

-- Карточка товара. product_category_name IS NULL = категория не указана.
CREATE TABLE core.products (
    product_id                 text PRIMARY KEY,
    product_category_name      text REFERENCES core.categories,
    product_name_length        integer,  -- product_name_lenght в raw
    product_description_length integer,  -- product_description_lenght в raw
    product_photos_qty         integer,
    product_weight_g           integer,
    product_length_cm          integer,
    product_height_cm          integer,
    product_width_cm           integer
);

-- Заказ. Хронология как в источнике; адрес — тот, что был в этом заказе
-- (raw.customers по customer_id), а не последний адрес покупателя.
CREATE TABLE core.orders (
    order_id                      text PRIMARY KEY,
    customer_id                   text NOT NULL UNIQUE,  -- «покупатель в заказе», 1:1 с заказом
    customer_unique_id            text NOT NULL REFERENCES core.customers,
    order_status                  text NOT NULL,
    order_purchase_timestamp      timestamp NOT NULL,
    order_approved_at             timestamp,
    order_delivered_carrier_date  timestamp,
    order_delivered_customer_date timestamp,
    order_estimated_delivery_date date,  -- в источнике всегда 00:00:00
    customer_zip_code_prefix      text,
    customer_city                 text,
    customer_state                text
);

-- Позиция заказа: одна единица товара одного продавца.
-- order_item_id — номер внутри заказа, а не идентификатор.
CREATE TABLE core.order_items (
    order_id            text      NOT NULL REFERENCES core.orders,
    order_item_id       integer   NOT NULL,
    product_id          text      NOT NULL REFERENCES core.products,
    seller_id           text      NOT NULL REFERENCES core.sellers,
    shipping_limit_date timestamp,
    price               numeric   NOT NULL CHECK (price >= 0),
    freight_value       numeric   NOT NULL CHECK (freight_value >= 0),
    PRIMARY KEY (order_id, order_item_id)
);

-- Платёж: относится ко всему заказу, не к позициям.
CREATE TABLE core.order_payments (
    order_id             text    NOT NULL REFERENCES core.orders,
    payment_sequential   integer NOT NULL,
    payment_type         text    NOT NULL,
    payment_installments integer,
    payment_value        numeric NOT NULL CHECK (payment_value >= 0),
    PRIMARY KEY (order_id, payment_sequential)
);

-- Отзыв. Ни review_id, ни order_id по отдельности не уникальны.
CREATE TABLE core.order_reviews (
    review_id               text     NOT NULL,
    order_id                text     NOT NULL REFERENCES core.orders,
    review_score            smallint NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title    text,
    review_comment_message  text,
    review_creation_date    timestamp,
    review_answer_timestamp timestamp,
    PRIMARY KEY (review_id, order_id)
);

-- Календарная ось: дни и месяцы без заказов не пропадают из отчётов.
CREATE TABLE core.calendar (
    day         date     PRIMARY KEY,
    month_start date     NOT NULL,  -- первое число месяца
    year        smallint NOT NULL,
    iso_dow     smallint NOT NULL   -- 1 = пн ... 7 = вс
);

-- Строки raw, не попавшие в core, с причиной.
-- Баланс по каждой таблице: raw = core + rejects.
CREATE TABLE core.etl_rejects (
    source_table text  NOT NULL,  -- имя таблицы в raw без схемы
    source_key   text,            -- ключ строки в источнике, если есть
    reason       text  NOT NULL,  -- код: duplicate_key, bad_type, orphan_fk, ...
    payload      jsonb NOT NULL   -- исходная строка целиком
);

CREATE INDEX ON core.orders (customer_unique_id);
CREATE INDEX ON core.orders (order_purchase_timestamp);
CREATE INDEX ON core.order_items (product_id);
CREATE INDEX ON core.order_items (seller_id);
CREATE INDEX ON core.order_reviews (order_id);
CREATE INDEX ON core.etl_rejects (source_table);
