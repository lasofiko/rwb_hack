"""Run Q1/Q2 on small fixtures in an EMPTY PostgreSQL test database.

Uses psycopg2 from setup.sh. Refuses a database with a core schema;
creates the draft A schema in a transaction and rolls it back afterwards.
Example: python queries/tests/test_q1_q2.py --dsn "$TEST_DATABASE_URL"
"""

import argparse
from datetime import date
from decimal import Decimal
from pathlib import Path

import psycopg2

ROOT = Path(__file__).resolve().parents[2]

FIXTURE = """
INSERT INTO core.customers VALUES ('u1');
INSERT INTO core.sellers (seller_id, seller_city, seller_state) VALUES
    ('s1', 'sao paulo', 'SP'), ('s2', 'rio', 'RJ'), ('s3', 'recife', 'PE');
INSERT INTO core.categories VALUES ('tools', 'tools');
INSERT INTO core.products (product_id, product_category_name) VALUES
    ('p1', 'tools'), ('p2', NULL);
INSERT INTO core.calendar (day, month_start, year, iso_dow)
SELECT d::date, d::date, EXTRACT(YEAR FROM d), EXTRACT(ISODOW FROM d)
FROM GENERATE_SERIES(DATE '2016-09-01', DATE '2018-08-01', INTERVAL '1 month') d;
INSERT INTO core.orders
    (order_id, customer_id, customer_unique_id, order_status, order_purchase_timestamp)
VALUES ('o1', 'c1', 'u1', 'delivered', '2016-09-15'),
       ('o2', 'c2', 'u1', 'canceled',  '2016-09-16'),
       ('o3', 'c3', 'u1', 'delivered', '2016-11-01'),
       ('o4', 'c4', 'u1', 'shipped',   '2016-11-02'),
       ('o5', 'c5', 'u1', 'delivered', '2018-09-01'),
       ('o6', 'c6', 'u1', 'delivered', '2016-11-03');
INSERT INTO core.order_items
    (order_id, order_item_id, product_id, seller_id, price, freight_value)
VALUES ('o1', 1, 'p1', 's1', 100, 10), ('o1', 2, 'p1', 's1', 100, 10),
       ('o1', 3, 'p2', 's2',  50,  5), ('o2', 1, 'p1', 's1', 999, 99),
       ('o3', 1, 'p1', 's1',  80,  8), ('o4', 1, 'p2', 's2', 777, 77),
       ('o5', 1, 'p2', 's2', 300, 30), ('o6', 1, 'p1', 's3', 350, 35);
INSERT INTO core.order_payments
    (order_id, payment_sequential, payment_type, payment_value)
VALUES ('o1', 1, 'credit_card', 200), ('o1', 2, 'voucher', 75);
INSERT INTO core.order_reviews (review_id, order_id, review_score)
VALUES ('r1', 'o1', 4), ('r2', 'o1', 5);
"""


def check_queries(cur):
    cur.execute((ROOT / 'queries/01_monthly_revenue.sql').read_text())
    actual = cur.fetchall()
    months = [date(y, m, 1) for y in (2016, 2017, 2018) for m in range(1, 13)
              if (2016, 9) <= (y, m) <= (2018, 8)]
    expected = [(m, 0, Decimal('0')) for m in months]
    expected[0] = (date(2016, 9, 1), 1, Decimal('250'))
    expected[2] = (date(2016, 11, 1), 2, Decimal('430'))
    if actual != expected:
        raise AssertionError(f'Q1: expected {expected!r}, got {actual!r}')

    cur.execute((ROOT / 'queries/02_top_sellers.sql').read_text())
    actual = cur.fetchall()
    expected = [
        ('s2', 'rio', 'RJ', 2, 2, Decimal('350')),
        ('s3', 'recife', 'PE', 1, 1, Decimal('350')),
        ('s1', 'sao paulo', 'SP', 2, 3, Decimal('280')),
    ]
    if actual != expected:
        raise AssertionError(f'Q2: expected {expected!r}, got {actual!r}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dsn', required=True, help='EMPTY PostgreSQL test database')
    args = parser.parse_args()
    conn = psycopg2.connect(args.dsn)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT to_regnamespace('core')")
            if cur.fetchone()[0] is not None:
                raise SystemExit('Refusing to use an existing core schema; use an empty test DB.')
            cur.execute('CREATE SCHEMA core')
            cur.execute((ROOT / 'model/10_ddl.sql').read_text())
            cur.execute(FIXTURE)
            check_queries(cur)
            cur.execute('TRUNCATE core.order_items, core.orders CASCADE')
            check_empty_queries(cur)
        print('Q1/Q2: fixtures and empty-order case passed; transaction rolled back.')
    finally:
        conn.rollback()
        conn.close()


def check_empty_queries(cur):
    cur.execute((ROOT / 'queries/01_monthly_revenue.sql').read_text())
    rows = cur.fetchall()
    if len(rows) != 24 or any(count != 0 or revenue != 0 for _, count, revenue in rows):
        raise AssertionError('Q1: calendar months must survive without orders')
    cur.execute((ROOT / 'queries/02_top_sellers.sql').read_text())
    if cur.fetchall():
        raise AssertionError('Q2: no delivered items must produce no sellers')


if __name__ == '__main__':
    main()
