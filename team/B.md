Задача: B — профиль 8 raw и загрузка по контракту v1 A (PR #8).
Статус: готово; ветка b/etl-v1, коммит с этим файлом — передача A.
A: подключить model/20_1_dims.sql → 20_2_orders.sql → 20_3_order_children.sql → 20_4_calendar.sql после DDL до mart.
Исправлено под v1: текст без trim (включая пробельные отзывы), reason-коды, source_key через |, CHECK рассрочки, границы календаря.
Проверка: два прогона совпали по всем 10 core-подписям; все числа v1 совпали, rejects=0; raw/деньги/тексты сохранены.
Результат: orders 99441, people 96096, items 112650, payments 103886, reviews 99224, products 32951, sellers 3095.
Categories 73 (2 без перевода), NULL category 610; calendar 821 день/27 месяцев, 2016-09-01—2018-11-30.
Fixture: 35 rejects, все коды v1, плохие типы/дубли/FK/домены, точный текст/ключи/нули/адреса/календарь — PASS.
Доказательства: profiling/etl-{verification,fixture}.jsonl; подключение сборки — A, независимые checks — D, ответы — C.
