Задача: B — профиль raw и ETL по контракту; повторно проверить и обновить rwb_hack.
Статус: профиль 853b042 готов; уточнение сумм выполнено; ETL ожидает контракт/DDL A.
Ветка: b/raw-profile-etl; текущий коммит с этим файлом — передача A без push.
Повторная проверка: origin/main=95f78db (метрики C v0), origin/a/base=9303929; контракта/DDL нет.
Файлы A/C/D: docs/data-quality.md, profiling/{01_raw_profile,02_followup,03_reconciliation}.sql + JSONL/SHA-256.
Проверка: 8 таблиц, 550759 строк; профиль 138 агрегатов; точечная сверка 14 JSON-записей, полный профиль не повторялся.
Факты A: review_id не PK; 610 NULL категорий, 13 товаров без перевода; все delivered имеют позиции, 1 без платежа.
Суммы C/D: payment−items−freight = −1819.51 + 162591.95 − 143.46 = 160628.98; см. reconciliation.jsonl.
Следующий шаг A: docs/contract.md + model/10_ddl.sql; затем B пишет model/20_*.sql и проверяет raw→core.
