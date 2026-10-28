# Ответы блока А — проверенный полный прогон

**Статус: штатная сборка проверена, все контроли Q1–Q5 сошлись.**
Две последовательные сборки дали одинаковые CSV-ответы.

Версия сборки, SQL, DDL и ETL: `109c9a96dca64491b28e2eacf964a55f271afc81`.
Контракт A: v1.1.
Дата запуска: 28.10.2026. PostgreSQL 16, отдельная временная база C.
Все восемь входных CSV совпадают по размеру и SHA-256 с
`profiling/source-manifest.json`. Ответы читают только core, raw не используется.

Выполнены первичная загрузка raw и два штатных `bash scripts/build.sh`.
SQL сборки не изменялся. Для изоляции использованы отдельные container name,
compose project, volume и порт; пять SELECT экспортированы из одной транзакции
REPEATABLE READ READ ONLY. Команды экспорта psql ниже также проверены.

| Запрос | Файл результата | Фактический контроль |
|---|---|---|
| Q1 | `01_monthly_revenue.csv` | 24 месяца, один нулевой; 13 221 498.11 BRL |
| Q2 | `02_top_sellers.csv` | Лидер 226 987.93 BRL |
| Q3 | `03_average_order.csv` | Чек 159.88 BRL; строки/единицы 1.142; заказов без позиций 0 |
| Q4 | `04_repeat_customers.csv` | 96 096 покупателей; 2 997 повторных; 3.12% |
| Q5 | `05_category_revenue.csv` | 74 группы; лидер 1 233 131.72 BRL; сумма 13 221 498.11 BRL |

`verification.json` содержит проверки, числа строк core и SHA-256 SQL.
Отклонённых строк в этом прогоне нет. Это не независимая проверка D.
Q3 включает доставку, товарная выручка Q1/Q2/Q5 — только цену товаров.
Повторный покупатель Q4 — человек с ≥2 оформлениями, все статусы.
В CSV пустой `category_key` означает NULL, подпись такой группы — `unknown`.

## Как воспроизвести

Подготовить raw один раз командой `bash scripts/setup.sh` из README проекта.
На том же снимке данных выполнить сборку и экспорт:

```bash
bash scripts/build.sh
mkdir -p results/block_a
for name in 01_monthly_revenue 02_top_sellers 03_average_order \
            04_repeat_customers 05_category_revenue; do
  docker compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 --csv \
    -P footer=off -U hack -d marketplace -f "/work/queries/$name.sql" \
    > "results/block_a/$name.csv"
done
```

Полные определения статусов, периодов и знаменателей: `docs/metrics.md`.
Сборка C не заменяет независимые инварианты и отчёты об аномалиях D.
