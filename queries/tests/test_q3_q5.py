"""Check all five queries in an EMPTY PostgreSQL database; roll fixtures back."""

import argparse
from decimal import Decimal

import psycopg2

from test_q1_q2 import ROOT, FIXTURE, check_queries, check_empty_queries


def rows(cur, filename):
    cur.execute((ROOT / 'queries' / filename).read_text())
    return cur.fetchall()


def expect(actual, expected):
    if actual != expected:
        raise AssertionError(f'Expected {expected!r}, got {actual!r}')


def check_new_queries(cur):
    expect(rows(cur, '03_average_order.sql'), [
        (Decimal('269.50'), Decimal('1.500'), Decimal('1.500'), 4, 0)
    ])
    cur.execute("""
        INSERT INTO core.customers VALUES ('u2'), ('u3'), ('u4');
        INSERT INTO core.orders
            (order_id, customer_id, customer_unique_id, order_status, order_purchase_timestamp)
        VALUES ('o7', 'c7', 'u2', 'canceled', '2017-01-01'),
               ('o8', 'c8', 'u2', 'shipped', '2017-01-02'),
               ('o9', 'c9', 'u3', 'canceled', '2017-01-03');
    """)
    # u1 and u2 have repeat orders; u4 without an order is not a buyer here.
    expect(rows(cur, '04_repeat_customers.sql'), [(3, 2, Decimal('66.67'))])
    expect(rows(cur, '05_category_revenue.sql'), [
        ('tools', 'tools', Decimal('630'), Decimal('64.29')),
        (None, 'unknown', Decimal('350'), Decimal('35.71')),
    ])

    cur.execute('SAVEPOINT extra_categories')
    cur.execute("""
        INSERT INTO core.categories VALUES ('untranslated', NULL), ('other_tools', 'tools');
        INSERT INTO core.products (product_id, product_category_name)
        VALUES ('p3', 'untranslated'), ('p4', 'other_tools');
        INSERT INTO core.order_items
            (order_id, order_item_id, product_id, seller_id, price, freight_value)
        VALUES ('o3', 2, 'p3', 's1', 20, 2), ('o3', 3, 'p4', 's1', 30, 3);
    """)
    categories = rows(cur, '05_category_revenue.sql')
    expect([(r[0], r[1], r[2]) for r in categories], [
        ('tools', 'tools', Decimal('630')), (None, 'unknown', Decimal('350')),
        ('other_tools', 'tools', Decimal('30')),
        ('untranslated', 'untranslated', Decimal('20')),
    ])
    expect(sum(r[2] for r in categories), Decimal('1030'))
    cur.execute('ROLLBACK TO SAVEPOINT extra_categories')

    cur.execute("""
        INSERT INTO core.orders
            (order_id, customer_id, customer_unique_id, order_status, order_purchase_timestamp)
        VALUES ('o10', 'c10', 'u4', 'delivered', '2017-01-04');
    """)
    expect(rows(cur, '03_average_order.sql'), [(None, None, None, 5, 1)])
    cur.execute('UPDATE core.order_items SET price = 0')
    categories = rows(cur, '05_category_revenue.sql')
    expect(len(categories), 2)
    if any(r[2] != 0 or r[3] is not None for r in categories):
        raise AssertionError('Q5: zero total revenue must give NULL percentages')

    cur.execute('TRUNCATE core.order_items, core.orders CASCADE')
    check_empty_queries(cur)
    expect(rows(cur, '03_average_order.sql'), [(None, None, None, 0, 0)])
    expect(rows(cur, '04_repeat_customers.sql'), [(0, 0, None)])
    expect(rows(cur, '05_category_revenue.sql'), [])


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
            check_new_queries(cur)
    finally:
        conn.rollback()
        conn.close()
    print('Q1–Q5: all fixture checks passed; transaction rolled back.')


if __name__ == '__main__':
    main()
