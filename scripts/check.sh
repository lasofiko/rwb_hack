#!/usr/bin/env bash
# =====================================================================
#  Проверки модели после сборки.
#
#      bash scripts/check.sh
#
#  checks/*.sql            обязательные инварианты: при нарушении файл
#                          делает RAISE EXCEPTION, запуск завершается
#                          ненулевым кодом
#  checks/anomalies/*.sql  известные аномалии данных: только отчёт,
#                          на код возврата влияет лишь ошибка SQL
#
#  Каждый файл — отдельный psql в транзакции с ROLLBACK: проверка
#  ничего не меняет в базе. Порядок — по имени файла.
# =====================================================================

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

db_up
shopt -s nullglob

total=0
failed=0

# $1 — путь к файлу от корня репозитория
run_check() {
  local out
  if out=$(psql_run -c 'BEGIN' -f "$1" -c 'ROLLBACK' 2>&1); then
    echo "  ок    $1"
    [ -n "$out" ] && echo "$out" | sed 's/^/        /'
    return 0
  fi
  echo "  FAIL  $1"
  echo "$out" | sed 's/^/        /'
  return 1
}

echo "==> Обязательные инварианты (checks/*.sql)"
for f in checks/*.sql; do
  total=$((total + 1))
  run_check "$f" || failed=$((failed + 1))
done
[ "$total" -gt 0 ] || echo "  ВНИМАНИЕ: обязательных проверок пока нет"

echo
echo "==> Известные аномалии (checks/anomalies/*.sql)"
for f in checks/anomalies/*.sql; do
  run_check "$f" || failed=$((failed + 1))
done

echo
if [ "$failed" -gt 0 ]; then
  echo "ОШИБКА: не прошло $failed файл(ов), подробности выше" >&2
  exit 1
fi
echo "    ок: обязательных проверок $total, все прошли"
