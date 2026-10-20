SET search_path TO fleet, public;

CREATE SEQUENCE trip_number_seq;

CREATE FUNCTION acting_user_id()
RETURNS INT
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('fleet.user_id', true), '')::INT;
$$;

CREATE FUNCTION short_person_name(p_last_name TEXT, p_first_name TEXT, p_middle_name TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT format('%s %s.%s',
                  p_last_name,
                  left(p_first_name, 1),
                  COALESCE(' ' || left(p_middle_name, 1) || '.', ''));
$$;

CREATE FUNCTION next_trip_number()
RETURNS TEXT
LANGUAGE sql VOLATILE AS $$
    SELECT format('TR-%s-%s', to_char(CURRENT_DATE, 'YYYY'), lpad(nextval('trip_number_seq')::TEXT, 6, '0'));
$$;


CREATE FUNCTION driver_has_category(p_driver_id INT, p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM vehicles                  v
        JOIN vehicle_models            m   ON m.model_id = v.model_id
        JOIN driver_license_categories dlc ON dlc.category = m.required_category
        WHERE v.vehicle_id = p_vehicle_id
          AND dlc.driver_id = p_driver_id
    );
$$;

CREATE FUNCTION vehicle_driver_on(p_vehicle_id INT, p_day DATE DEFAULT CURRENT_DATE)
RETURNS INT
LANGUAGE sql STABLE AS $$
    SELECT driver_id
    FROM vehicle_assignments
    WHERE vehicle_id = p_vehicle_id
      AND active_during @> p_day;
$$;

CREATE FUNCTION vehicle_is_free(p_vehicle_id INT, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (
               SELECT 1
               FROM trips
               WHERE vehicle_id = p_vehicle_id
                 AND status <> 'cancelled'
                 AND tstzrange(planned_start, planned_end) && tstzrange(p_from, p_to))
       AND NOT EXISTS (
               SELECT 1
               FROM maintenance_records
               WHERE vehicle_id = p_vehicle_id
                 AND status = 'in_progress');
$$;

CREATE FUNCTION vehicle_fuel_per_100km(p_vehicle_id INT, p_from DATE, p_to DATE)
RETURNS NUMERIC(6,2)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = fleet, public
AS $$
    WITH driven AS (
        SELECT SUM(distance_km) AS km
        FROM trips
        WHERE vehicle_id = p_vehicle_id
          AND status = 'completed'
          AND finished_at::DATE BETWEEN p_from AND p_to
    ),
    fueled AS (
        SELECT SUM(quantity) AS litres
        FROM fuel_transactions
        WHERE vehicle_id = p_vehicle_id
          AND filled_at::DATE BETWEEN p_from AND p_to
    )
    SELECT round(COALESCE(fueled.litres, 0) * 100 / NULLIF(driven.km, 0), 2)
    FROM driven, fueled;
$$;

CREATE FUNCTION vehicle_total_cost(p_vehicle_id INT)
RETURNS NUMERIC(14,2)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = fleet, public
AS $$
    WITH fuel AS (
        SELECT COALESCE(SUM(total_cost), 0) AS amount
        FROM fuel_transactions
        WHERE vehicle_id = p_vehicle_id
    ),
    service AS (
        SELECT COALESCE(SUM(i.line_total), 0) AS amount
        FROM maintenance_records mr
        JOIN maintenance_items   i ON i.maintenance_id = mr.maintenance_id
        WHERE mr.vehicle_id = p_vehicle_id
          AND mr.status = 'completed'
    ),
    damage AS (
        SELECT COALESCE(SUM(amount), 0) AS amount
        FROM incidents
        WHERE vehicle_id = p_vehicle_id
    )
    SELECT (fuel.amount + service.amount + damage.amount)::NUMERIC(14,2)
    FROM fuel, service, damage;
$$;

CREATE FUNCTION next_maintenance_due(p_vehicle_id INT, p_maintenance_type_id INT)
RETURNS TABLE (last_km INT, last_on DATE, due_km INT, due_on DATE)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = fleet, public
AS $$
    WITH last_done AS (
        SELECT odometer_km, completed_at::DATE AS done_on
        FROM maintenance_records
        WHERE vehicle_id = p_vehicle_id
          AND maintenance_type_id = p_maintenance_type_id
          AND status = 'completed'
        ORDER BY completed_at DESC
        LIMIT 1
    )
    SELECT ld.odometer_km,
           ld.done_on,
           COALESCE(ld.odometer_km, 0) + t.every_km,
           COALESCE(ld.done_on, v.purchase_date, v.created_at::DATE) + t.every_days
    FROM vehicles               v
    CROSS JOIN maintenance_types t
    LEFT JOIN last_done         ld ON TRUE
    WHERE v.vehicle_id = p_vehicle_id
      AND t.maintenance_type_id = p_maintenance_type_id;
$$;


CREATE FUNCTION require_active_vehicle(p_vehicle_id INT)
RETURNS vehicles
LANGUAGE plpgsql AS $$
DECLARE
    v_vehicle vehicles;
BEGIN
    SELECT * INTO v_vehicle
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id
      AND deleted_at IS NULL
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активне авто % не знайдено', p_vehicle_id;
    END IF;
    RETURN v_vehicle;
END $$;

CREATE FUNCTION require_active_driver(p_driver_id INT)
RETURNS drivers
LANGUAGE plpgsql AS $$
DECLARE
    v_driver drivers;
BEGIN
    SELECT * INTO v_driver
    FROM drivers
    WHERE driver_id = p_driver_id
      AND deleted_at IS NULL
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Активного водія % не знайдено', p_driver_id;
    END IF;
    RETURN v_driver;
END $$;

CREATE FUNCTION require_trip(p_trip_id INT, p_expected trip_status)
RETURNS trips
LANGUAGE plpgsql AS $$
DECLARE
    v_trip trips;
BEGIN
    SELECT * INTO v_trip
    FROM trips
    WHERE trip_id = p_trip_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Рейс % не знайдено', p_trip_id;
    END IF;
    IF v_trip.status <> p_expected THEN
        RAISE EXCEPTION 'Рейс % має статус %, а потрібен %', v_trip.trip_number, v_trip.status, p_expected;
    END IF;
    RETURN v_trip;
END $$;

CREATE FUNCTION require_maintenance(p_maintenance_id INT, p_expected maintenance_status)
RETURNS maintenance_records
LANGUAGE plpgsql AS $$
DECLARE
    v_record maintenance_records;
BEGIN
    SELECT * INTO v_record
    FROM maintenance_records
    WHERE maintenance_id = p_maintenance_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ТО % не знайдено', p_maintenance_id;
    END IF;
    IF v_record.status <> p_expected THEN
        RAISE EXCEPTION 'ТО % має статус %, а потрібен %', p_maintenance_id, v_record.status, p_expected;
    END IF;
    RETURN v_record;
END $$;

CREATE FUNCTION require_no_open_trips(
    p_vehicle_id  INT DEFAULT NULL,
    p_driver_id   INT DEFAULT NULL,
    p_customer_id INT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM trips
        WHERE status IN ('planned', 'in_progress')
          AND (vehicle_id = p_vehicle_id OR driver_id = p_driver_id OR customer_id = p_customer_id)
    ) THEN
        RAISE EXCEPTION '% має незавершені рейси, спершу завершіть або скасуйте їх',
            CASE
                WHEN p_vehicle_id IS NOT NULL THEN 'Авто ' || p_vehicle_id
                WHEN p_driver_id  IS NOT NULL THEN 'Водій ' || p_driver_id
                ELSE 'Замовник ' || p_customer_id
            END;
    END IF;
END $$;
