"""Execute D checks and negative controls in a disposable PostgreSQL 16 container.

Requires a dedicated empty database d_checks_fixture. Every case rolls back its
synthetic schemas; this never connects to marketplace or loads the team's raw.
No third-party Python packages. Docker/container lifecycle belongs to the caller.
"""

import argparse
import subprocess
import sys


def run_case(container, name, checks, mutation="", expected_error=None):
    script = "\\set ON_ERROR_STOP on\nBEGIN;\n\\ir /work/checks/fixtures/v1.sql\n"
    script += mutation + "\n"
    script += "\n".join(f"\\ir /work/checks/{path}" for path in checks)
    script += "\nROLLBACK;\n"
    result = subprocess.run(
        ["docker", "exec", "-i", "-w", "/work", container, "psql", "-X", "-q",
         "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "d_checks_fixture"],
        input=script, text=True, encoding="utf-8", capture_output=True, timeout=120,
    )
    combined = result.stdout + result.stderr
    if expected_error is None:
        passed = result.returncode == 0
    else:
        passed = result.returncode != 0 and expected_error in combined
    if not passed:
        print(f"FAIL {name}: exit={result.returncode}", file=sys.stderr)
        print("\n".join(combined.splitlines()[-12:]), file=sys.stderr)
        return False
    print(f"PASS {name}")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    parser.add_argument("--probe-etl", action="store_true",
                        help="probe current B ETL on the fixture; return nonzero on v1 mismatch")
    args = parser.parse_args()
    # Prefix is deliberately fixed: don't target the team's postgres by mistake.
    if not args.container.startswith("rwb-d-quality-"):
        parser.error("container must start with rwb-d-quality-")
    if args.probe_etl:
        mutation = (
            "DROP SCHEMA core CASCADE;\nCREATE SCHEMA core;\n"
            "\\ir /work/model/10_ddl.sql\n"
            "\\ir /work/model/20_1_dims.sql\n\\ir /work/model/20_2_orders.sql\n"
            "\\ir /work/model/20_3_order_children.sql\n\\ir /work/model/20_4_calendar.sql\n"
        )
        passed = run_case(args.container, "current B ETL vs v1", ["30_source_reconciliation.sql"], mutation)
        print("This is a synthetic integration probe; real input data NOT tested.")
        return 0 if passed else 1
    cases = [
        ("all six checks and anomaly reports", [
            "00_synthetic.sql", "10_catalog.sql", "20_keys_and_types.sql",
            "30_source_reconciliation.sql", "40_join_and_money.sql", "50_calendar.sql",
            "anomalies/10_orders.sql", "anomalies/20_payments_reviews.sql",
            "anomalies/30_categories_rejects.sql", "tools/snapshot.sql",
        ], "", None),
        ("valid quarantine preserves source balance", ["30_source_reconciliation.sql"],
         "WITH rejected AS (INSERT INTO raw.order_items "
         "(order_id, order_item_id, product_id, seller_id, price, freight_value) "
         "VALUES ('o3', '1', 'p1', 's1', 'bad', '0') RETURNING *) "
         "INSERT INTO core.etl_rejects SELECT 'order_items', 'o3|1', 'bad_type:price', to_jsonb(r) FROM rejected r;",
         None),
        ("duplicate key rejects every source copy", ["30_source_reconciliation.sql"],
         "INSERT INTO raw.order_reviews SELECT * FROM raw.order_reviews WHERE review_id='r1' AND order_id='o2'; "
         "DELETE FROM core.order_reviews WHERE review_id='r1' AND order_id='o2'; "
         "INSERT INTO core.etl_rejects SELECT 'order_reviews', 'r1|o2', 'duplicate_key', to_jsonb(r) "
         "FROM raw.order_reviews r WHERE review_id='r1' AND order_id='o2';",
         None),
        ("reject missing raw payload", ["30_source_reconciliation.sql"],
         "INSERT INTO core.etl_rejects VALUES ('orders', 'missing', 'duplicate_key', '{}'::jsonb);",
         "reject provenance orders"),
        ("reject overcounted raw payload", ["30_source_reconciliation.sql"],
         "INSERT INTO core.etl_rejects SELECT 'orders', order_id, 'duplicate_key', to_jsonb(r) "
         "FROM raw.orders r CROSS JOIN generate_series(1,2) n WHERE order_id='o1';",
         "reject provenance orders"),
        ("reject unknown reason", ["30_source_reconciliation.sql"],
         "INSERT INTO core.etl_rejects SELECT 'orders', order_id, 'invented_reason', to_jsonb(r) FROM raw.orders r LIMIT 1;",
         "reject reasons follow v1 dictionary"),
        ("reject trimmed review text", ["30_source_reconciliation.sql"],
         "UPDATE core.order_reviews SET review_comment_message = btrim(review_comment_message);",
         "source reconciliation order_reviews"),
        ("reject trimmed city", ["30_source_reconciliation.sql"],
         "UPDATE core.sellers SET seller_city = btrim(seller_city);",
         "source reconciliation sellers"),
        ("reject subcent rounding", ["30_source_reconciliation.sql"],
         "UPDATE core.order_items SET price = round(price, 2);",
         "source reconciliation order_items"),
        ("reject FK orphan", ["20_keys_and_types.sql"],
         "ALTER TABLE core.order_items DROP CONSTRAINT order_items_product_id_fkey; "
         "UPDATE core.order_items SET product_id = 'missing' WHERE order_id = 'o2';",
         "FK: order_items.product_id"),
        ("reject calendar hole", ["50_calendar.sql"],
         "DELETE FROM core.calendar WHERE day = date '2016-10-15';",
         "calendar missing days"),
    ]
    results = [run_case(args.container, *case) for case in cases]
    print(f"Synthetic D checks: {sum(results)}/{len(results)} passed. Real ETL/data NOT tested.")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
