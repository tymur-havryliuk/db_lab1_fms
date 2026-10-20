SET search_path TO fleet, public;

CREATE PROCEDURE sp_vehicle_register(
    p_vin              TEXT,
    p_plate_number     TEXT,
    p_model_id         INT,
    p_depot_id         INT,
    p_manufacture_year INT,
    p_odometer_km      INT     DEFAULT 0,
    p_purchase_date    DATE    DEFAULT NULL,
    p_purchase_price   NUMERIC DEFAULT NULL,
    p_color            TEXT    DEFAULT NULL,
    INOUT p_vehicle_id INT     DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_vin   TEXT := upper(p_vin);
    v_plate TEXT := upper(p_plate_number);
BEGIN
    IF NOT vin_is_valid(v_vin) THEN
        RAISE EXCEPTION 'Некоректний VIN %: не збігається контрольна цифра', p_vin;
    END IF;
    IF EXISTS (SELECT 1 FROM vehicles WHERE vin = v_vin AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Авто з VIN % уже є в автопарку', v_vin;
    END IF;
    IF EXISTS (SELECT 1 FROM vehicles WHERE plate_number = v_plate AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Номер % уже зареєстрований', v_plate;
    END IF;
    IF EXISTS (SELECT 1 FROM depots WHERE depot_id = p_depot_id AND deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Депо % в архіві', p_depot_id;
    END IF;

    INSERT INTO vehicles (vin, plate_number, model_id, depot_id, manufacture_year,
                          odometer_km, purchase_date, purchase_price, color)
    VALUES (v_vin, v_plate, p_model_id, p_depot_id, p_manufacture_year,
            COALESCE(p_odometer_km, 0), p_purchase_date, p_purchase_price, p_color)
    RETURNING vehicle_id INTO p_vehicle_id;
END $$;

CREATE PROCEDURE sp_vehicle_update(
    p_vehicle_id   INT,
    p_plate_number TEXT DEFAULT NULL,
    p_depot_id     INT  DEFAULT NULL,
    p_color        TEXT DEFAULT NULL,
    p_notes        TEXT DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    PERFORM require_active_vehicle(p_vehicle_id);

    UPDATE vehicles
    SET plate_number = COALESCE(upper(p_plate_number), plate_number),
        depot_id     = COALESCE(p_depot_id, depot_id),
        color        = COALESCE(p_color, color),
        notes        = COALESCE(p_notes, notes)
    WHERE vehicle_id = p_vehicle_id;
END $$;

CREATE PROCEDURE sp_vehicle_decommission(p_vehicle_id INT, p_reason TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_vehicle vehicles := require_active_vehicle(p_vehicle_id);
BEGIN
    IF v_vehicle.status = 'decommissioned' THEN
        RAISE EXCEPTION 'Авто % уже списане', v_vehicle.plate_number;
    END IF;
    PERFORM require_no_open_trips(p_vehicle_id => p_vehicle_id);

    UPDATE vehicles
    SET status = 'decommissioned',
        notes  = concat_ws(E'\n', notes, 'Списано: ' || p_reason)
    WHERE vehicle_id = p_vehicle_id;

    CALL sp_assignments_close(p_vehicle_id => p_vehicle_id);
END $$;

CREATE PROCEDURE sp_vehicle_archive(p_vehicle_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    PERFORM require_active_vehicle(p_vehicle_id);
    PERFORM require_no_open_trips(p_vehicle_id => p_vehicle_id);

    IF EXISTS (SELECT 1 FROM maintenance_records WHERE vehicle_id = p_vehicle_id AND status = 'in_progress') THEN
        RAISE EXCEPTION 'Авто % зараз на ТО', p_vehicle_id;
    END IF;

    UPDATE vehicles
    SET deleted_at = now(),
        deleted_by = acting_user_id()
    WHERE vehicle_id = p_vehicle_id;

    CALL sp_assignments_close(p_vehicle_id => p_vehicle_id);
END $$;

CREATE PROCEDURE sp_vehicle_restore(p_vehicle_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_vehicle vehicles;
BEGIN
    SELECT * INTO v_vehicle
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id
      AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Авто % немає в архіві', p_vehicle_id;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM vehicles
        WHERE deleted_at IS NULL
          AND (vin = v_vehicle.vin OR plate_number = v_vehicle.plate_number)
    ) THEN
        RAISE EXCEPTION 'Активне авто з VIN % або номером % уже існує', v_vehicle.vin, v_vehicle.plate_number;
    END IF;

    UPDATE vehicles
    SET deleted_at = NULL,
        deleted_by = NULL
    WHERE vehicle_id = p_vehicle_id;
END $$;

CREATE PROCEDURE sp_insurance_add(
    p_vehicle_id      INT,
    p_policy_type     TEXT,
    p_insurer         TEXT,
    p_policy_number   TEXT,
    p_valid_from      DATE,
    p_valid_to        DATE,
    p_premium         NUMERIC,
    INOUT p_policy_id INT DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    PERFORM require_active_vehicle(p_vehicle_id);

    IF p_valid_to < p_valid_from THEN
        RAISE EXCEPTION 'Поліс % закінчується раніше, ніж починається', p_policy_number;
    END IF;

    INSERT INTO insurance_policies (vehicle_id, policy_type, insurer, policy_number, valid_during, premium)
    VALUES (p_vehicle_id, p_policy_type, p_insurer, p_policy_number,
            daterange(p_valid_from, p_valid_to, '[]'), p_premium)
    RETURNING policy_id INTO p_policy_id;
END $$;


CREATE PROCEDURE sp_driver_hire(
    p_last_name       TEXT,
    p_first_name      TEXT,
    p_middle_name     TEXT,
    p_birth_date      DATE,
    p_phone           TEXT,
    p_email           TEXT,
    p_license_number  TEXT,
    p_license_expires DATE,
    p_depot_id        INT,
    p_categories      TEXT[],
    p_hired_on        DATE DEFAULT CURRENT_DATE,
    INOUT p_driver_id INT  DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_license TEXT := upper(p_license_number);
BEGIN
    IF EXISTS (SELECT 1 FROM drivers WHERE license_number = v_license AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Водій з посвідченням % уже працює', v_license;
    END IF;
    IF p_license_expires <= CURRENT_DATE THEN
        RAISE EXCEPTION 'Посвідчення % прострочене (%)', v_license, p_license_expires;
    END IF;
    IF COALESCE(cardinality(p_categories), 0) = 0 THEN
        RAISE EXCEPTION 'Вкажіть хоча б одну категорію посвідчення';
    END IF;

    INSERT INTO drivers (last_name, first_name, middle_name, birth_date, phone, email,
                         license_number, license_expires, hired_on, depot_id)
    VALUES (p_last_name, p_first_name, p_middle_name, p_birth_date, p_phone, p_email,
            v_license, p_license_expires, COALESCE(p_hired_on, CURRENT_DATE), p_depot_id)
    RETURNING driver_id INTO p_driver_id;

    INSERT INTO driver_license_categories (driver_id, category)
    SELECT DISTINCT p_driver_id, upper(category)
    FROM unnest(p_categories) AS category;
END $$;

CREATE PROCEDURE sp_driver_update(
    p_driver_id       INT,
    p_phone           TEXT DEFAULT NULL,
    p_email           TEXT DEFAULT NULL,
    p_license_expires DATE DEFAULT NULL,
    p_depot_id        INT  DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    PERFORM require_active_driver(p_driver_id);

    UPDATE drivers
    SET phone           = COALESCE(p_phone, phone),
        email           = COALESCE(p_email, email),
        license_expires = COALESCE(p_license_expires, license_expires),
        depot_id        = COALESCE(p_depot_id, depot_id)
    WHERE driver_id = p_driver_id;
END $$;

CREATE PROCEDURE sp_driver_set_categories(p_driver_id INT, p_categories TEXT[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_categories TEXT[] := ARRAY(SELECT DISTINCT upper(c) FROM unnest(p_categories) AS c);
    v_required   TEXT;
BEGIN
    PERFORM require_active_driver(p_driver_id);

    SELECT m.required_category INTO v_required
    FROM vehicle_assignments a
    JOIN vehicles            v ON v.vehicle_id = a.vehicle_id
    JOIN vehicle_models      m ON m.model_id   = v.model_id
    WHERE a.driver_id = p_driver_id
      AND a.active_during @> CURRENT_DATE
      AND m.required_category <> ALL (v_categories);

    IF v_required IS NOT NULL THEN
        RAISE EXCEPTION 'Категорія % потрібна для закріпленого авто', v_required;
    END IF;

    DELETE FROM driver_license_categories
    WHERE driver_id = p_driver_id
      AND category <> ALL (v_categories);

    INSERT INTO driver_license_categories (driver_id, category)
    SELECT p_driver_id, unnest(v_categories)
    ON CONFLICT DO NOTHING;
END $$;

CREATE PROCEDURE sp_driver_dismiss(p_driver_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    PERFORM require_active_driver(p_driver_id);
    PERFORM require_no_open_trips(p_driver_id => p_driver_id);

    UPDATE drivers
    SET deleted_at = now(),
        deleted_by = acting_user_id()
    WHERE driver_id = p_driver_id;

    CALL sp_assignments_close(p_driver_id => p_driver_id);
END $$;

CREATE PROCEDURE sp_driver_reinstate(p_driver_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_driver drivers;
BEGIN
    SELECT * INTO v_driver
    FROM drivers
    WHERE driver_id = p_driver_id
      AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Водія % немає серед звільнених', p_driver_id;
    END IF;
    IF EXISTS (SELECT 1 FROM drivers WHERE license_number = v_driver.license_number AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Активний водій з посвідченням % уже існує', v_driver.license_number;
    END IF;

    UPDATE drivers
    SET deleted_at = NULL,
        deleted_by = NULL
    WHERE driver_id = p_driver_id;
END $$;

CREATE PROCEDURE sp_assignments_close(
    p_vehicle_id INT  DEFAULT NULL,
    p_driver_id  INT  DEFAULT NULL,
    p_on         DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    DELETE FROM vehicle_assignments
    WHERE (vehicle_id = p_vehicle_id OR driver_id = p_driver_id)
      AND lower(active_during) >= p_on;

    UPDATE vehicle_assignments
    SET active_during = daterange(lower(active_during), p_on)
    WHERE (vehicle_id = p_vehicle_id OR driver_id = p_driver_id)
      AND active_during @> p_on;
END $$;

CREATE PROCEDURE sp_driver_assign(
    p_vehicle_id          INT,
    p_driver_id           INT,
    p_start_on            DATE DEFAULT CURRENT_DATE,
    p_note                TEXT DEFAULT NULL,
    INOUT p_assignment_id INT  DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_start DATE := COALESCE(p_start_on, CURRENT_DATE);
BEGIN
    IF NOT driver_has_category(p_driver_id, p_vehicle_id) THEN
        RAISE EXCEPTION 'Водій % не має категорії для авто %', p_driver_id, p_vehicle_id;
    END IF;

    CALL sp_assignments_close(p_vehicle_id, p_driver_id, v_start);

    INSERT INTO vehicle_assignments (vehicle_id, driver_id, active_during, note, created_by)
    VALUES (p_vehicle_id, p_driver_id, daterange(v_start, NULL), p_note, acting_user_id())
    RETURNING assignment_id INTO p_assignment_id;
END $$;


CREATE PROCEDURE sp_trip_plan(
    p_vehicle_id        INT,
    p_driver_id         INT,
    p_route_id          INT,
    p_customer_id       INT,
    p_planned_start     TIMESTAMPTZ,
    p_cargo             TEXT    DEFAULT NULL,
    p_cargo_weight_kg   INT     DEFAULT NULL,
    p_freight_price     NUMERIC DEFAULT NULL,
    INOUT p_trip_id     INT     DEFAULT NULL,
    INOUT p_trip_number TEXT    DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_driver_id INT := COALESCE(p_driver_id, vehicle_driver_on(p_vehicle_id, p_planned_start::DATE));
    v_route     routes;
    v_payload   INT;
BEGIN
    IF v_driver_id IS NULL THEN
        RAISE EXCEPTION 'За авто % не закріплено водія, вкажіть його явно', p_vehicle_id;
    END IF;

    SELECT * INTO v_route FROM routes WHERE route_id = p_route_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Маршрут % недоступний', p_route_id;
    END IF;

    IF EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id AND deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Замовник % в архіві', p_customer_id;
    END IF;

    SELECT m.payload_kg INTO v_payload
    FROM vehicles       v
    JOIN vehicle_models m ON m.model_id = v.model_id
    WHERE v.vehicle_id = p_vehicle_id;

    IF p_cargo_weight_kg > v_payload THEN
        RAISE EXCEPTION 'Вантаж % кг перевищує вантажопідйомність авто (% кг)', p_cargo_weight_kg, v_payload;
    END IF;

    p_trip_number := next_trip_number();

    INSERT INTO trips (trip_number, vehicle_id, driver_id, route_id, customer_id,
                       planned_start, planned_end, cargo, cargo_weight_kg, freight_price)
    VALUES (p_trip_number, p_vehicle_id, v_driver_id, p_route_id, p_customer_id,
            p_planned_start,
            p_planned_start + make_interval(mins => (v_route.duration_hours * 60)::INT),
            p_cargo, p_cargo_weight_kg, p_freight_price)
    RETURNING trip_id INTO p_trip_id;
END $$;

CREATE PROCEDURE sp_trip_start(p_trip_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_trip    trips    := require_trip(p_trip_id, 'planned');
    v_vehicle vehicles := require_active_vehicle(v_trip.vehicle_id);
BEGIN
    IF v_vehicle.status <> 'active' THEN
        RAISE EXCEPTION 'Авто % зараз недоступне (%)', v_vehicle.plate_number, v_vehicle.status;
    END IF;
    IF EXISTS (SELECT 1 FROM trips WHERE vehicle_id = v_trip.vehicle_id AND status = 'in_progress') THEN
        RAISE EXCEPTION 'Авто % уже в іншому рейсі', v_vehicle.plate_number;
    END IF;

    UPDATE trips
    SET status         = 'in_progress',
        started_at     = now(),
        odometer_start = v_vehicle.odometer_km
    WHERE trip_id = p_trip_id;
END $$;

CREATE PROCEDURE sp_trip_finish(p_trip_id INT, p_odometer_end INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_trip trips := require_trip(p_trip_id, 'in_progress');
BEGIN
    IF p_odometer_end < v_trip.odometer_start THEN
        RAISE EXCEPTION 'Одометр на фініші (%) менший, ніж на старті (%)', p_odometer_end, v_trip.odometer_start;
    END IF;

    UPDATE trips
    SET status       = 'completed',
        finished_at  = now(),
        odometer_end = p_odometer_end
    WHERE trip_id = p_trip_id;
END $$;

CREATE PROCEDURE sp_trip_cancel(p_trip_id INT, p_reason TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    PERFORM require_trip(p_trip_id, 'planned');

    IF NULLIF(trim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'Вкажіть причину скасування';
    END IF;

    UPDATE trips
    SET status        = 'cancelled',
        cancel_reason = p_reason
    WHERE trip_id = p_trip_id;
END $$;

CREATE PROCEDURE sp_fuel_add(
    p_vehicle_id       INT,
    p_driver_id        INT,
    p_quantity         NUMERIC,
    p_unit_price       NUMERIC,
    p_odometer_km      INT,
    p_station          TEXT   DEFAULT NULL,
    INOUT p_fuel_tx_id BIGINT DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_vehicle   vehicles := require_active_vehicle(p_vehicle_id);
    v_fuel_type INT;
BEGIN
    IF p_odometer_km < v_vehicle.odometer_km THEN
        RAISE EXCEPTION 'Пробіг при заправці (%) менший за поточний пробіг авто (%)',
            p_odometer_km, v_vehicle.odometer_km;
    END IF;

    SELECT fuel_type_id INTO v_fuel_type
    FROM vehicle_models
    WHERE model_id = v_vehicle.model_id;

    INSERT INTO fuel_transactions (vehicle_id, driver_id, fuel_type_id, quantity, unit_price,
                                   odometer_km, station, created_by)
    VALUES (p_vehicle_id, COALESCE(p_driver_id, vehicle_driver_on(p_vehicle_id)), v_fuel_type,
            p_quantity, p_unit_price, p_odometer_km, p_station, acting_user_id())
    RETURNING fuel_tx_id INTO p_fuel_tx_id;
END $$;

CREATE PROCEDURE sp_incident_register(
    p_vehicle_id        INT,
    p_driver_id         INT,
    p_trip_id           INT,
    p_type              incident_type,
    p_occurred_at       TIMESTAMPTZ,
    p_location          TEXT,
    p_description       TEXT,
    p_amount            NUMERIC DEFAULT 0,
    p_driver_at_fault   BOOLEAN DEFAULT FALSE,
    INOUT p_incident_id INT     DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    c_serious_damage CONSTANT NUMERIC := 10000;
    v_driver_id      INT := p_driver_id;
BEGIN
    IF p_trip_id IS NOT NULL THEN
        SELECT COALESCE(v_driver_id, driver_id) INTO v_driver_id
        FROM trips
        WHERE trip_id = p_trip_id
          AND vehicle_id = p_vehicle_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Рейс % не належить авто %', p_trip_id, p_vehicle_id;
        END IF;
    END IF;

    INSERT INTO incidents (vehicle_id, driver_id, trip_id, type, occurred_at, location,
                           description, amount, driver_at_fault)
    VALUES (p_vehicle_id, v_driver_id, p_trip_id, p_type, COALESCE(p_occurred_at, now()), p_location,
            p_description, COALESCE(p_amount, 0), COALESCE(p_driver_at_fault, FALSE))
    RETURNING incident_id INTO p_incident_id;

    IF p_type IN ('accident', 'breakdown') AND p_amount >= c_serious_damage THEN
        UPDATE vehicles
        SET status = 'in_service'
        WHERE vehicle_id = p_vehicle_id
          AND status = 'active';

        INSERT INTO maintenance_records (vehicle_id, maintenance_type_id, scheduled_on, description)
        SELECT p_vehicle_id, t.maintenance_type_id, CURRENT_DATE, 'Ремонт після інциденту: ' || p_description
        FROM maintenance_types t
        WHERE t.code = 'REPAIR'
          AND NOT EXISTS (
              SELECT 1
              FROM maintenance_records mr
              WHERE mr.vehicle_id = p_vehicle_id
                AND mr.maintenance_type_id = t.maintenance_type_id
                AND mr.status IN ('scheduled', 'in_progress'));
    END IF;
END $$;


CREATE PROCEDURE sp_maintenance_schedule(
    p_vehicle_id           INT,
    p_maintenance_code     TEXT,
    p_scheduled_on         DATE,
    p_provider_id          INT  DEFAULT NULL,
    p_description          TEXT DEFAULT NULL,
    INOUT p_maintenance_id INT  DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_vehicle vehicles := require_active_vehicle(p_vehicle_id);
    v_type_id INT;
BEGIN
    SELECT maintenance_type_id INTO v_type_id
    FROM maintenance_types
    WHERE code = upper(p_maintenance_code);

    IF v_type_id IS NULL THEN
        RAISE EXCEPTION 'Невідомий вид ТО %', p_maintenance_code;
    END IF;
    IF v_vehicle.status = 'decommissioned' THEN
        RAISE EXCEPTION 'Авто % списане', v_vehicle.plate_number;
    END IF;
    IF EXISTS (SELECT 1 FROM service_providers WHERE provider_id = p_provider_id AND deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'СТО % в архіві', p_provider_id;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM maintenance_records
        WHERE vehicle_id = p_vehicle_id
          AND maintenance_type_id = v_type_id
          AND status IN ('scheduled', 'in_progress')
    ) THEN
        RAISE EXCEPTION 'Для авто % уже заплановано %', v_vehicle.plate_number, p_maintenance_code;
    END IF;

    INSERT INTO maintenance_records (vehicle_id, maintenance_type_id, provider_id, scheduled_on, description)
    VALUES (p_vehicle_id, v_type_id, p_provider_id, COALESCE(p_scheduled_on, CURRENT_DATE), p_description)
    RETURNING maintenance_id INTO p_maintenance_id;
END $$;

CREATE PROCEDURE sp_maintenance_start(p_maintenance_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    PERFORM require_maintenance(p_maintenance_id, 'scheduled');

    UPDATE maintenance_records
    SET status     = 'in_progress',
        started_at = now()
    WHERE maintenance_id = p_maintenance_id;
END $$;

CREATE PROCEDURE sp_maintenance_add_item(
    p_maintenance_id INT,
    p_kind           TEXT,
    p_description    TEXT,
    p_quantity       NUMERIC,
    p_unit_price     NUMERIC,
    INOUT p_item_id  INT DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_status maintenance_status;
BEGIN
    SELECT status INTO v_status
    FROM maintenance_records
    WHERE maintenance_id = p_maintenance_id;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'ТО % не знайдено', p_maintenance_id;
    END IF;
    IF v_status NOT IN ('scheduled', 'in_progress') THEN
        RAISE EXCEPTION 'ТО % уже закрите (%), рядки додавати не можна', p_maintenance_id, v_status;
    END IF;

    INSERT INTO maintenance_items (maintenance_id, kind, description, quantity, unit_price)
    VALUES (p_maintenance_id, p_kind, p_description, p_quantity, p_unit_price)
    RETURNING item_id INTO p_item_id;
END $$;

CREATE PROCEDURE sp_maintenance_complete(p_maintenance_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_record maintenance_records := require_maintenance(p_maintenance_id, 'in_progress');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM maintenance_items WHERE maintenance_id = p_maintenance_id) THEN
        RAISE EXCEPTION 'ТО % не має жодного рядка робіт', p_maintenance_id;
    END IF;

    UPDATE maintenance_records
    SET status       = 'completed',
        completed_at = now(),
        odometer_km  = (SELECT odometer_km FROM vehicles WHERE vehicle_id = v_record.vehicle_id)
    WHERE maintenance_id = p_maintenance_id;
END $$;

CREATE PROCEDURE sp_maintenance_cancel(p_maintenance_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    UPDATE maintenance_records
    SET status = 'cancelled'
    WHERE maintenance_id = p_maintenance_id
      AND status IN ('scheduled', 'in_progress');

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Незакрите ТО % не знайдено', p_maintenance_id;
    END IF;
END $$;


CREATE PROCEDURE sp_session_begin(p_user_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM app_users WHERE user_id = p_user_id AND is_active) THEN
        RAISE EXCEPTION 'Активного користувача % не знайдено', p_user_id;
    END IF;

    PERFORM set_config('fleet.user_id', p_user_id::TEXT, true);
END $$;

CREATE PROCEDURE sp_customer_archive(p_customer_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    PERFORM require_no_open_trips(p_customer_id => p_customer_id);

    UPDATE customers
    SET deleted_at = now(),
        deleted_by = acting_user_id()
    WHERE customer_id = p_customer_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активного замовника % не знайдено', p_customer_id;
    END IF;
END $$;

CREATE PROCEDURE sp_customer_restore(p_customer_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_customer customers;
BEGIN
    SELECT * INTO v_customer
    FROM customers
    WHERE customer_id = p_customer_id
      AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Замовника % немає в архіві', p_customer_id;
    END IF;
    IF EXISTS (SELECT 1 FROM customers WHERE tax_code = v_customer.tax_code AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Активний замовник з кодом % уже існує', v_customer.tax_code;
    END IF;

    UPDATE customers
    SET deleted_at = NULL,
        deleted_by = NULL
    WHERE customer_id = p_customer_id;
END $$;

CREATE PROCEDURE sp_depot_archive(p_depot_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM vehicles WHERE depot_id = p_depot_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'У депо % ще є авто, спершу переведіть їх в інше депо', p_depot_id;
    END IF;
    IF EXISTS (SELECT 1 FROM drivers WHERE depot_id = p_depot_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'У депо % ще працюють водії', p_depot_id;
    END IF;

    UPDATE depots
    SET deleted_at = now(),
        deleted_by = acting_user_id()
    WHERE depot_id = p_depot_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активне депо % не знайдено', p_depot_id;
    END IF;
END $$;

CREATE PROCEDURE sp_depot_restore(p_depot_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_depot depots;
BEGIN
    SELECT * INTO v_depot
    FROM depots
    WHERE depot_id = p_depot_id
      AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Депо % немає в архіві', p_depot_id;
    END IF;
    IF EXISTS (SELECT 1 FROM depots WHERE code = v_depot.code AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Активне депо з кодом % уже існує', v_depot.code;
    END IF;

    UPDATE depots
    SET deleted_at = NULL,
        deleted_by = NULL
    WHERE depot_id = p_depot_id;
END $$;

CREATE PROCEDURE sp_route_archive(p_route_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM trips WHERE route_id = p_route_id AND status IN ('planned', 'in_progress')) THEN
        RAISE EXCEPTION 'На маршруті % є незавершені рейси', p_route_id;
    END IF;

    UPDATE routes
    SET deleted_at = now(),
        deleted_by = acting_user_id()
    WHERE route_id = p_route_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активний маршрут % не знайдено', p_route_id;
    END IF;
END $$;

CREATE PROCEDURE sp_route_restore(p_route_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
DECLARE
    v_route routes;
BEGIN
    SELECT * INTO v_route
    FROM routes
    WHERE route_id = p_route_id
      AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Маршруту % немає в архіві', p_route_id;
    END IF;
    IF EXISTS (SELECT 1 FROM routes WHERE code = v_route.code AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Активний маршрут з кодом % уже існує', v_route.code;
    END IF;

    UPDATE routes
    SET deleted_at = NULL,
        deleted_by = NULL
    WHERE route_id = p_route_id;
END $$;

CREATE PROCEDURE sp_provider_archive(p_provider_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM maintenance_records
        WHERE provider_id = p_provider_id
          AND status IN ('scheduled', 'in_progress')
    ) THEN
        RAISE EXCEPTION 'У СТО % є незакриті ТО', p_provider_id;
    END IF;

    UPDATE service_providers
    SET deleted_at = now(),
        deleted_by = acting_user_id()
    WHERE provider_id = p_provider_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активне СТО % не знайдено', p_provider_id;
    END IF;
END $$;

CREATE PROCEDURE sp_provider_restore(p_provider_id INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    UPDATE service_providers
    SET deleted_at = NULL,
        deleted_by = NULL
    WHERE provider_id = p_provider_id
      AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'СТО % немає в архіві', p_provider_id;
    END IF;
END $$;

CREATE PROCEDURE sp_reports_refresh()
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = fleet, public
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW mv_monthly_costs;
END $$;


REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA fleet FROM PUBLIC;

GRANT USAGE ON SCHEMA fleet TO fleet_app;

GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA fleet TO fleet_app;

GRANT EXECUTE ON FUNCTION
    short_person_name(TEXT, TEXT, TEXT),
    next_maintenance_due(INT, INT),
    vehicle_fuel_per_100km(INT, DATE, DATE),
    vehicle_total_cost(INT)
TO fleet_app;

GRANT SELECT ON
    v_active_vehicles,
    v_active_drivers,
    v_current_assignments,
    v_trips,
    v_maintenance_due,
    v_maintenance_records,
    v_fuel_consumption,
    v_vehicle_costs,
    v_expiring_documents,
    v_driver_performance,
    v_audit_trail,
    v_deleted_records,
    mv_monthly_costs
TO fleet_app;
