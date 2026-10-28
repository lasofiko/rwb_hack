-- Подключать через \ir внутри транзакции check.sh. Не запускать отдельной проверкой.
CREATE TEMP TABLE IF NOT EXISTS d_check_session (unused boolean) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(label text, actual boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF actual IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'D check failed: % (actual=%)', label, actual;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.assert_numeric(label text, actual numeric, expected numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'D check failed: % (actual=%, expected=%)', label, actual, expected;
    END IF;
END;
$$;
