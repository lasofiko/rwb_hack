Задача: B — профиль 8 raw-таблиц, факты A, затем ETL по контракту.
Статус: профиль выполнен на PostgreSQL 16.15; ETL заблокирован отсутствием контракта/DDL.
Ветка: b/raw-profile-etl; worktree: ../rwb_hack_b; передача — коммит с этим файлом.
A: факты и предложения в docs/data-quality.md; SQL/JSONL/SHA-256 в profiling/.
Проверка: 550759 строк, 138 агрегатов; PK-кандидаты уникальны, бизнес-дублей нет; FK без сирот кроме категорий.
Важно A: review_id не уникален (789 ID); пара review_id+order_id уникальна; 610 NULL категорий, 13 товаров без перевода.
БД B: localhost:55432/marketplace_b, hack/hack, Compose project rwb-b; raw после загрузки не изменялся.
Блокер/следующий шаг A: docs/contract.md + model/10_ddl.sql (core-поля, PK/FK, NULL/unknown, reject-политика, сборка).
После контракта B реализует model/20_*.sql и проверит баланс/суммы; до этого core-интерфейс не выдумывается.
