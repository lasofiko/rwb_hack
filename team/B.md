Задача: B — ETL raw→core по контракту A v0; профиль уже в main через PR #6.
Статус: model/20_load_core.sql реализован и проверен; ветка b/core-etl, коммит с этим файлом — передача A.
A: добавить \ir 20_load_core.sql после \ir 10_ddl.sql и до mart в model/build.sql; утвердить контракт v1.
Проверка: два прогона PostgreSQL 16.15 совпали по всем core-подписям; raw неизменён, деньги сохранены, rejects=0.
Результат: orders 99441, people 96096, items 112650, payments 103886, reviews 99224, products 32951, sellers 3095.
Categories 73; calendar 821 день (2016-09-01—2018-11-30); сохранены 610 NULL категорий и 2 категории без перевода.
Fixture: 32 rejects, плохие типы/дубли/FK/домены, текст/NULL/нулевые суммы, адреса/календарь/хронология — PASS.
Файлы: docs/data-quality.md, profiling/etl-{verification,fixture}.jsonl, profiling/contract-facts.jsonl; инструкции в profiling/README.md.
Следующий шаг: PR B → A подключает файл и фиксирует v1 → C выполняет запросы → D независимо проверяет сборку.
