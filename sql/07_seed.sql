SET search_path TO fleet, public;

INSERT INTO app_users (login, full_name, role, email) VALUES
    ('admin',       'Адміністратор системи',     'admin',         'admin@fleet.example.com'),
    ('mkovalenko',  'Коваленко Марина Олегівна', 'dispatcher',    'm.kovalenko@fleet.example.com'),
    ('vbondar',     'Бондар Віктор Степанович',  'mechanic',      'v.bondar@fleet.example.com'),
    ('ishevchenko', 'Шевченко Ігор Петрович',    'fleet_manager', 'i.shevchenko@fleet.example.com');

SELECT set_config('fleet.user_id', '1', false);

INSERT INTO cities (name, oblast) VALUES
    ('Київ',    NULL),
    ('Львів',   'Львівська'),
    ('Дніпро',  'Дніпропетровська'),
    ('Одеса',   'Одеська'),
    ('Харків',  'Харківська'),
    ('Вінниця', 'Вінницька'),
    ('Житомир', 'Житомирська'),
    ('Рівне',   'Рівненська');

INSERT INTO fuel_types (code, title, unit) VALUES
    ('diesel',   'Дизельне пальне', 'l'),
    ('a95',      'Бензин А-95',     'l'),
    ('lpg',      'Скраплений газ',  'l'),
    ('electric', 'Електроенергія',  'kWh');

INSERT INTO license_categories (category, description) VALUES
    ('B',  'Легкові авто та малі вантажівки до 3,5 т'),
    ('C1', 'Вантажівки 3,5-7,5 т'),
    ('C',  'Вантажівки понад 3,5 т'),
    ('CE', 'Вантажівки з причепом і сідельні тягачі'),
    ('D1', 'Автобуси до 16 пасажирів'),
    ('D',  'Автобуси');

INSERT INTO vehicle_makes (name, country) VALUES
    ('Volvo',         'Швеція'),
    ('MAN',           'Німеччина'),
    ('Mercedes-Benz', 'Німеччина'),
    ('Renault',       'Франція'),
    ('Ford',          'США'),
    ('Toyota',        'Японія');

INSERT INTO vehicle_models (make_id, name, body_type, fuel_type_id, required_category, payload_kg, seats, fuel_norm_per_100km) VALUES
    (1, 'FH 460',           'tractor', 1, 'CE', 20000, 2, 32.0),
    (2, 'TGX 18.470',       'tractor', 1, 'CE', 20000, 2, 31.5),
    (2, 'TGL 8.190',        'truck',   1, 'C',   4500, 3, 19.0),
    (3, 'Sprinter 316 CDI', 'van',     1, 'B',   1400, 3, 11.5),
    (4, 'Master dCi 150',   'van',     1, 'B',   1500, 3, 10.8),
    (5, 'Transit Custom',   'van',     1, 'B',   1100, 3,  9.5),
    (6, 'Hilux 2.4 D-4D',   'pickup',  1, 'B',   1000, 5, 10.0);

INSERT INTO maintenance_types (code, title, every_km, every_days) VALUES
    ('TO1',   'ТО-1: олива та фільтри',          15000, 180),
    ('TO2',   'ТО-2: комплексне обслуговування', 60000, 365),
    ('TIRES', 'Сезонна заміна шин',               NULL, 180),
    ('REPAIR', 'Позаплановий ремонт',              NULL, NULL);

INSERT INTO depots (code, name, city_id, address, phone, capacity, manager_id) VALUES
    ('KYIV-01',   'Автобаза Київ-Борщагівка',     1, 'вул. Генерала Наумова, 23', '+380445551010', 40, 4),
    ('LVIV-01',   'Автобаза Львів-Сихів',         2, 'вул. Зелена, 301',          '+380322551020', 25, NULL),
    ('DNIPRO-01', 'Автобаза Дніпро-Лівобережна',  3, 'вул. Байкальська, 11',      '+380562551030', 30, NULL);

INSERT INTO service_providers (name, city_id, address, phone, rating) VALUES
    ('СТО «Автодок Сервіс»', 1, 'вул. Пирогівський шлях, 135', '+380445553030', 4.6),
    ('Truck Service Захід',  2, 'вул. Городоцька, 355',        '+380322553040', 4.8),
    ('СТО «Мотор-Дніпро»',   3, 'просп. Слобожанський, 77',    '+380562553050', 4.2);

INSERT INTO customers (name, tax_code, city_id, address, contact_person, phone, email) VALUES
    ('ТОВ «Нова Агро»',            '41234567',   1, 'просп. Перемоги, 120',    'Іваненко Петро', '+380442223301', 'logistics@nova-agro.example.com'),
    ('ПрАТ «Галицькі солодощі»',   '32345678',   2, 'вул. Личаківська, 45',    'Гнатюк Ольга',   '+380322223302', 'supply@sweets.example.com'),
    ('ТОВ «Дніпро Метал Трейд»',   '43456789',   3, 'вул. Кайдацький шлях, 3', 'Литвин Роман',   '+380562223303', 'orders@dmt.example.com'),
    ('ФОП Савчук Олена Ігорівна',  '3012345678', 6, 'вул. Соборна, 12',        'Савчук Олена',   '+380432223304', NULL),
    ('ТОВ «Одеса Порт Сервіс»',    '44567890',   4, 'Митна пл., 1',            'Кравець Денис',  '+380482223305', 'cargo@ops.example.com');

INSERT INTO routes (code, name, from_city_id, to_city_id, distance_km, duration_hours) VALUES
    ('KYIV-LVIV',      'Київ — Львів',    1, 2, 540, 7.5),
    ('KYIV-ODESA',     'Київ — Одеса',    1, 4, 475, 6.5),
    ('DNIPRO-KHARKIV', 'Дніпро — Харків', 3, 5, 215, 3.5),
    ('LVIV-RIVNE',     'Львів — Рівне',   2, 8, 210, 3.0),
    ('KYIV-ZHYTOMYR',  'Київ — Житомир',  1, 7, 140, 2.0),
    ('DNIPRO-KYIV',    'Дніпро — Київ',   3, 1, 480, 6.5),
    ('KYIV-VINNYTSIA', 'Київ — Вінниця',  1, 6, 270, 3.5),
    ('LVIV-KYIV',      'Львів — Київ',    2, 1, 540, 7.5),
    ('ODESA-KYIV',     'Одеса — Київ',    4, 1, 475, 6.5);


INSERT INTO vehicles (vin, plate_number, model_id, depot_id, manufacture_year, purchase_date, purchase_price, odometer_km, color) VALUES
    ('YV2RT40A2LB123456', 'AA1001KA', 1, 1, 2020, '2020-03-15', 3450000, 412000, 'білий'),
    ('YV2RT40A5MB234567', 'AA2002KB', 1, 1, 2021, '2021-05-20', 3700000, 305000, 'синій'),
    ('WMA06XZZ9KM345678', 'BC3003AM', 2, 2, 2019, '2019-08-01', 3100000, 498340, 'червоний'),
    ('WMA06XZZ3LP456789', 'BC4004AH', 3, 2, 2020, '2020-10-10', 1850000, 187000, 'білий'),
    ('WDB9066300S567890', 'AE5005KC', 4, 3, 2018, '2018-04-12', 1150000, 264210, 'сріблястий'),
    ('VF1MA000768678901', 'AA6006MP', 5, 1, 2016, '2016-09-01',  820000, 321125, 'білий'),
    ('WF0XXXTT9XKA78901', 'AE7007HT', 6, 3, 2019, '2019-02-18',  960000, 158000, 'сірий'),
    ('JTEBR3FJ2K5012345', 'AA8008TO', 7, 1, 2019, '2019-06-30', 1250000,  98000, 'чорний');

INSERT INTO drivers (last_name, first_name, middle_name, birth_date, phone, email, license_number, license_expires, hired_on, depot_id) VALUES
    ('Петренко',   'Олександр', 'Іванович',    '1980-03-12', '+380501112201', 'o.petrenko@fleet.example.com',   'BXA100001', CURRENT_DATE + 900,  '2015-04-01', 1),
    ('Коваль',     'Андрій',    'Миколайович', '1985-07-23', '+380501112202', 'a.koval@fleet.example.com',      'BXA100002', CURRENT_DATE + 20,   '2017-02-15', 1),
    ('Мельник',    'Сергій',    'Петрович',    '1978-11-05', '+380671112203', 's.melnyk@fleet.example.com',     'BCA100003', CURRENT_DATE + 1200, '2012-09-10', 2),
    ('Бондаренко', 'Василь',    'Олегович',    '1990-01-30', '+380671112204', NULL,                             'BCA100004', CURRENT_DATE + 600,  '2019-05-20', 2),
    ('Ткаченко',   'Ірина',     'Вікторівна',  '1993-06-14', '+380931112205', 'i.tkachenko@fleet.example.com',  'AEA100005', CURRENT_DATE + 1500, '2020-03-02', 3),
    ('Шевчук',     'Дмитро',    'Романович',   '1988-09-09', '+380931112206', NULL,                             'AEA100006', CURRENT_DATE + 400,  '2018-11-12', 3),
    ('Кравченко',  'Оксана',    'Андріївна',   '1995-12-01', '+380501112207', 'o.kravchenko@fleet.example.com', 'BXA100007', CURRENT_DATE + 1100, '2021-06-01', 1),
    ('Олійник',    'Максим',    'Юрійович',    '1983-04-18', '+380501112208', NULL,                             'BXA100008', CURRENT_DATE + 800,  '2016-08-08', 1);

INSERT INTO driver_license_categories (driver_id, category)
SELECT driver_id, unnest(categories)
FROM (VALUES
    (1, ARRAY['B', 'C', 'CE']),
    (2, ARRAY['B', 'C', 'CE']),
    (3, ARRAY['B', 'C', 'CE']),
    (4, ARRAY['B', 'C']),
    (5, ARRAY['B']),
    (6, ARRAY['B', 'C']),
    (7, ARRAY['B']),
    (8, ARRAY['B', 'C', 'D'])
) AS driver_categories (driver_id, categories);

INSERT INTO vehicle_assignments (vehicle_id, driver_id, active_during, created_by)
SELECT vehicle_id, driver_id, daterange(CURRENT_DATE - 200, NULL), acting_user_id()
FROM (VALUES (1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 7), (7, 6), (8, 8)) AS pairs (vehicle_id, driver_id);

INSERT INTO insurance_policies (vehicle_id, policy_type, insurer, policy_number, valid_during, premium)
SELECT vehicle_id,
       'osago',
       'СК «Оберіг»',
       'EP-' || (210000000 + vehicle_id),
       CASE WHEN vehicle_id IN (2, 6)
            THEN daterange(CURRENT_DATE - 350, CURRENT_DATE + 15)
            ELSE daterange(CURRENT_DATE - 300, CURRENT_DATE + 65)
       END,
       CASE WHEN vehicle_id <= 3 THEN 7800 ELSE 3200 END
FROM generate_series(1, 8) AS vehicle_id;

INSERT INTO insurance_policies (vehicle_id, policy_type, insurer, policy_number, valid_during, premium)
SELECT vehicle_id,
       'kasko',
       'СК «Захист Авто»',
       'KA-' || (310000000 + vehicle_id),
       daterange(CURRENT_DATE - 100, CURRENT_DATE + 265),
       98000
FROM generate_series(1, 3) AS vehicle_id;


WITH plan (n, vehicle_id, driver_id, route_id, customer_id, status, days_ago, start_time,
           late_start_min, late_finish_min, odometer_start, odometer_end, cargo, weight_kg, price, cancel_reason) AS (
    VALUES
        ( 1, 1, 1, 1, 2, 'completed', 50, TIME '06:00', 10,  20, 410905, 411457, 'Борошно в мішках',    18000, 38000.00, NULL),
        ( 2, 1, 1, 8, 2, 'completed', 48, TIME '07:00',  5, -10, 411457, 412000, 'Кондитерські вироби', 12000, 36500.00, NULL),
        ( 3, 2, 2, 2, 5, 'completed', 30, TIME '05:00',  0,  -5, 304040, 304521, 'Контейнер 40ft',      19500, 34000.00, NULL),
        ( 4, 2, 2, 9, 5, 'completed', 28, TIME '06:00', 15,  60, 304521, 305000, 'Контейнер 40ft',      19000, 34000.00, NULL),
        ( 5, 3, 3, 4, 2, 'completed', 20, TIME '08:00',  0, -15, 497580, 497792, 'Цукор',               15000, 16000.00, NULL),
        ( 6, 3, 3, 8, 1, 'completed', 15, TIME '06:00', 20,  35, 497792, 498340, 'Мінеральні добрива',  20000, 39000.00, NULL),
        ( 7, 4, 4, 4, 4, 'completed', 25, TIME '09:00',  0,   0, 186580, 186795, 'Меблі',                3500,  9800.00, NULL),
        ( 8, 5, 5, 3, 3, 'completed', 12, TIME '07:00', 10,  45, 263500, 263722, 'Метизи',               1200,  7200.00, NULL),
        ( 9, 5, 5, 6, 3, 'completed', 10, TIME '06:00',  0, -20, 263722, 264210, 'Електроінструмент',     900, 14500.00, NULL),
        (10, 6, 7, 5, 1, 'completed',  7, TIME '08:00',  0,  -5, 320700, 320846, 'Насіння',              1300,  5200.00, NULL),
        (11, 6, 7, 7, 4, 'completed',  5, TIME '07:00',  5,  50, 320846, 321125, 'Побутова техніка',     1100,  8900.00, NULL),
        (12, 7, 6, 3, 3, 'completed',  3, TIME '08:00',  0,  10, 157700, 157921, 'Запчастини',            800,  6800.00, NULL),
        (13, 8, 8, 5, 1, 'completed',  9, TIME '10:00',  0, -10,  97800,  97945, 'Документи та зразки',   150,  3500.00, NULL),
        (14, 2, 2, 7, 4, 'cancelled', 20, TIME '08:00', NULL, NULL, NULL, NULL,  'Побутова техніка',     8000, 12000.00, 'Замовник переніс відвантаження'),
        (15, 1, 1, 1, 1, 'planned',   -2, TIME '06:00', NULL, NULL, NULL, NULL,  'Комбікорм',           17000, 37000.00, NULL),
        (16, 3, 3, 8, 2, 'planned',   -3, TIME '06:00', NULL, NULL, NULL, NULL,  'Цукрова продукція',   16000, 38500.00, NULL)
),
timed AS (
    SELECT p.*,
           (CURRENT_DATE - p.days_ago + p.start_time)::TIMESTAMPTZ                AS planned_start,
           (CURRENT_DATE - p.days_ago + p.start_time)::TIMESTAMPTZ
               + make_interval(mins => (r.duration_hours * 60)::INT)               AS planned_end
    FROM plan   p
    JOIN routes r USING (route_id)
)
INSERT INTO trips (trip_number, vehicle_id, driver_id, route_id, customer_id, status,
                   planned_start, planned_end, started_at, finished_at,
                   odometer_start, odometer_end, cargo, cargo_weight_kg, freight_price, cancel_reason)
SELECT format('TR-%s-%s', to_char(CURRENT_DATE, 'YYYY'), lpad(n::TEXT, 6, '0')),
       vehicle_id, driver_id, route_id, customer_id, status::trip_status,
       planned_start,
       planned_end,
       planned_start + make_interval(mins => late_start_min),
       planned_end   + make_interval(mins => late_finish_min),
       odometer_start, odometer_end, cargo, weight_kg, price, cancel_reason
FROM timed
ORDER BY n;

SELECT setval('trip_number_seq', (SELECT count(*) FROM trips));

INSERT INTO fuel_transactions (vehicle_id, driver_id, fuel_type_id, filled_at, quantity, unit_price, odometer_km, station, created_by)
SELECT vehicle_id,
       vehicle_driver_on(vehicle_id),
       1,
       (CURRENT_DATE - days_ago + TIME '05:30')::TIMESTAMPTZ,
       litres,
       price,
       odometer_km,
       station,
       acting_user_id()
FROM (VALUES
    (1, 51, 190.0, 54.20, 410900, 'WOG, Київ, Кільцева дорога'),
    (1, 49, 192.0, 54.50, 411457, 'OKKO, Львів, вул. Городоцька'),
    (2, 31, 160.0, 54.10, 304040, 'WOG, Київ, Одеська пл.'),
    (2, 29, 158.0, 53.90, 304521, 'SOCAR, Одеса, Київське шосе'),
    (3, 21,  75.0, 54.80, 497580, 'OKKO, Львів, вул. Зелена'),
    (3, 16, 185.0, 54.60, 497792, 'UPG, Рівне, траса М-06'),
    (4, 26,  42.0, 54.70, 186580, 'OKKO, Львів, вул. Зелена'),
    (5, 13,  26.0, 53.80, 263500, 'WOG, Дніпро, просп. Слобожанський'),
    (5, 11,  58.0, 54.00, 263722, 'SOCAR, Харків, просп. Гагаріна'),
    (6,  8,  16.0, 54.30, 320700, 'WOG, Київ, Кільцева дорога'),
    (6,  6,  34.0, 54.40, 320846, 'OKKO, Житомир, траса М-06'),
    (7,  4,  22.0, 53.90, 157700, 'UPG, Дніпро, вул. Байкальська'),
    (8,  9,  15.0, 54.30,  97800, 'WOG, Київ, просп. Перемоги')
) AS fills (vehicle_id, days_ago, litres, price, odometer_km, station);

INSERT INTO maintenance_records (vehicle_id, maintenance_type_id, provider_id, status, scheduled_on,
                                 started_at, completed_at, odometer_km, description)
SELECT h.vehicle_id,
       t.maintenance_type_id,
       v.depot_id,
       'completed',
       CURRENT_DATE - h.days_ago,
       (CURRENT_DATE - h.days_ago + TIME '09:00')::TIMESTAMPTZ,
       (CURRENT_DATE - h.days_ago + TIME '14:00')::TIMESTAMPTZ,
       h.odometer_km,
       'Планове обслуговування'
FROM (VALUES
    (1, 'TO1',   405000,  60), (2, 'TO1',   296000,  90), (3, 'TO1',   483500,  70), (4, 'TO1',   178000, 170),
    (5, 'TO1',   255000,  80), (6, 'TO1',   312000,  40), (7, 'TO1',   150000, 100), (8, 'TO1',    90000, 120),
    (1, 'TO2',   380000, 200), (2, 'TO2',   250000, 300), (3, 'TO2',   450000, 250), (4, 'TO2',   140000, 360),
    (5, 'TO2',   210000, 330), (6, 'TO2',   270000, 150), (7, 'TO2',   110000, 200), (8, 'TO2',    60000, 300),
    (1, 'TIRES', 395000, 150), (2, 'TIRES', 285000, 170), (3, 'TIRES', 470000, 150), (4, 'TIRES', 175000, 150),
    (5, 'TIRES', 250000, 150), (6, 'TIRES', 305000, 170), (7, 'TIRES', 145000, 150), (8, 'TIRES',  88000, 150)
) AS h (vehicle_id, code, odometer_km, days_ago)
JOIN maintenance_types t ON t.code       = h.code
JOIN vehicles          v ON v.vehicle_id = h.vehicle_id
ORDER BY h.days_ago DESC;

SET fleet.allow_closed_edit = 'on';

INSERT INTO maintenance_items (maintenance_id, kind, description, quantity, unit_price)
SELECT mr.maintenance_id,
       item.kind,
       item.description,
       CASE m.body_type WHEN 'tractor' THEN item.qty_heavy WHEN 'truck' THEN item.qty_medium ELSE item.qty_light END,
       CASE m.body_type WHEN 'tractor' THEN item.price_heavy ELSE item.price_light END
FROM maintenance_records mr
JOIN maintenance_types   t ON t.maintenance_type_id = mr.maintenance_type_id
JOIN vehicles            v ON v.vehicle_id          = mr.vehicle_id
JOIN vehicle_models      m ON m.model_id            = v.model_id
JOIN (VALUES
    ('TO1',   'part',  'Моторна олива 10W-40, л',                            40,  20,   8,  285.00,  320.00),
    ('TO1',   'part',  'Комплект фільтрів (оливний, паливний, повітряний)',  1,   1,   1, 6800.00, 2100.00),
    ('TO1',   'labor', 'Роботи ТО-1, год',                                    3, 2.5, 1.5,  950.00,  950.00),
    ('TO2',   'labor', 'Комплексна діагностика, год',                         4,   4,   3,  950.00,  950.00),
    ('TO2',   'part',  'Гальмівні колодки, комплект',                         1,   1,   1, 9800.00, 3600.00),
    ('TO2',   'part',  'Технічні рідини (антифриз, гальмівна)',               1,   1,   1, 2400.00, 2400.00),
    ('TIRES', 'labor', 'Шиномонтаж і балансування, колесо',                  10,   6,   4,  450.00,  450.00)
) AS item (code, kind, description, qty_heavy, qty_medium, qty_light, price_heavy, price_light)
    ON item.code = t.code
ORDER BY mr.maintenance_id;

RESET fleet.allow_closed_edit;

INSERT INTO maintenance_records (vehicle_id, maintenance_type_id, provider_id, status, scheduled_on, started_at, description) VALUES
    (4, 2, 2, 'in_progress', CURRENT_DATE - 1, (CURRENT_DATE - 1 + TIME '09:00')::TIMESTAMPTZ, 'ТО-2 за графіком'),
    (2, 3, 1, 'scheduled',   CURRENT_DATE + 5, NULL,                                            'Перехід на сезонні шини');

INSERT INTO maintenance_items (maintenance_id, kind, description, quantity, unit_price)
SELECT maintenance_id, 'labor', 'Комплексна діагностика, год', 3, 950.00
FROM maintenance_records
WHERE vehicle_id = 4
  AND status = 'in_progress';

INSERT INTO incidents (vehicle_id, driver_id, trip_id, type, occurred_at, location, description, amount, driver_at_fault, is_resolved) VALUES
    (3, 3,  6, 'fine',      (CURRENT_DATE - 15 + TIME '09:30')::TIMESTAMPTZ, 'Траса М-06, Житомирська обл.',
     'Перевищення швидкості на 25 км/год',  340, TRUE,  TRUE),
    (5, 5,  8, 'accident',  (CURRENT_DATE - 12 + TIME '09:10')::TIMESTAMPTZ, 'Харків, просп. Гагаріна',
     'Зачеплення дзеркала при паркуванні', 4800, TRUE,  TRUE),
    (6, 7, 11, 'breakdown', (CURRENT_DATE - 5  + TIME '08:40')::TIMESTAMPTZ, 'Траса М-21',
     'Пробито колесо, заміна на запасне',  1200, FALSE, TRUE);

SELECT set_config('fleet.user_id', '', false);

CALL sp_reports_refresh();
ANALYZE;
