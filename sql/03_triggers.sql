SET search_path TO fleet, public;

CREATE FUNCTION tg_touch_row()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_by := COALESCE(NEW.created_by, acting_user_id());
    END IF;
    NEW.modified_at := now();
    NEW.modified_by := COALESCE(acting_user_id(), NEW.modified_by);
    RETURN NEW;
END $$;

CREATE FUNCTION tg_write_change_log()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    c_ignored   CONSTANT TEXT[] := ARRAY['modified_at', 'modified_by'];
    c_id_column CONSTANT TEXT   := TG_ARGV[0];
    v_old       JSONB := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
    v_new       JSONB := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
    v_action    change_action;
    v_change_id BIGINT;
BEGIN
    IF TG_OP = 'UPDATE' AND NOT EXISTS (
        SELECT 1
        FROM jsonb_each(v_new) AS field
        WHERE field.key <> ALL (c_ignored)
          AND field.value IS DISTINCT FROM v_old -> field.key
    ) THEN
        RETURN NULL;
    END IF;

    v_action := CASE
        WHEN TG_OP = 'INSERT' THEN 'created'
        WHEN TG_OP = 'DELETE' THEN 'deleted'
        WHEN v_old ->> 'deleted_at' IS NULL AND v_new ->> 'deleted_at' IS NOT NULL THEN 'archived'
        WHEN v_old ->> 'deleted_at' IS NOT NULL AND v_new ->> 'deleted_at' IS NULL THEN 'restored'
        ELSE 'updated'
    END;

    INSERT INTO change_log (table_name, record_id, action, changed_by)
    VALUES (TG_TABLE_NAME, (COALESCE(v_new, v_old) ->> c_id_column)::INT, v_action, acting_user_id())
    RETURNING change_id INTO v_change_id;

    IF TG_OP = 'UPDATE' THEN
        INSERT INTO change_log_fields (change_id, field_name, old_value, new_value)
        SELECT v_change_id, field.key, v_old ->> field.key, v_new ->> field.key
        FROM jsonb_each(v_new) AS field
        WHERE field.key <> ALL (c_ignored)
          AND field.value IS DISTINCT FROM v_old -> field.key;
    END IF;

    RETURN NULL;
END $$;

CREATE FUNCTION tg_forbid_hard_delete()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('fleet.allow_hard_delete', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Записи з % не видаляються фізично, використовуйте архівацію', TG_TABLE_NAME;
    END IF;
    RETURN OLD;
END $$;

CREATE TRIGGER trg_depots_touch              BEFORE INSERT OR UPDATE ON depots              FOR EACH ROW EXECUTE FUNCTION tg_touch_row();
CREATE TRIGGER trg_vehicles_touch            BEFORE INSERT OR UPDATE ON vehicles            FOR EACH ROW EXECUTE FUNCTION tg_touch_row();
CREATE TRIGGER trg_drivers_touch             BEFORE INSERT OR UPDATE ON drivers             FOR EACH ROW EXECUTE FUNCTION tg_touch_row();
CREATE TRIGGER trg_customers_touch           BEFORE INSERT OR UPDATE ON customers           FOR EACH ROW EXECUTE FUNCTION tg_touch_row();
CREATE TRIGGER trg_routes_touch              BEFORE INSERT OR UPDATE ON routes              FOR EACH ROW EXECUTE FUNCTION tg_touch_row();
CREATE TRIGGER trg_trips_touch               BEFORE INSERT OR UPDATE ON trips               FOR EACH ROW EXECUTE FUNCTION tg_touch_row();
CREATE TRIGGER trg_maintenance_records_touch BEFORE INSERT OR UPDATE ON maintenance_records FOR EACH ROW EXECUTE FUNCTION tg_touch_row();
CREATE TRIGGER trg_incidents_touch           BEFORE INSERT OR UPDATE ON incidents           FOR EACH ROW EXECUTE FUNCTION tg_touch_row();

CREATE TRIGGER trg_depots_change_log              AFTER INSERT OR UPDATE OR DELETE ON depots              FOR EACH ROW EXECUTE FUNCTION tg_write_change_log('depot_id');
CREATE TRIGGER trg_vehicles_change_log            AFTER INSERT OR UPDATE OR DELETE ON vehicles            FOR EACH ROW EXECUTE FUNCTION tg_write_change_log('vehicle_id');
CREATE TRIGGER trg_drivers_change_log             AFTER INSERT OR UPDATE OR DELETE ON drivers             FOR EACH ROW EXECUTE FUNCTION tg_write_change_log('driver_id');
CREATE TRIGGER trg_customers_change_log           AFTER INSERT OR UPDATE OR DELETE ON customers           FOR EACH ROW EXECUTE FUNCTION tg_write_change_log('customer_id');
CREATE TRIGGER trg_routes_change_log              AFTER INSERT OR UPDATE OR DELETE ON routes              FOR EACH ROW EXECUTE FUNCTION tg_write_change_log('route_id');
CREATE TRIGGER trg_trips_change_log               AFTER INSERT OR UPDATE OR DELETE ON trips               FOR EACH ROW EXECUTE FUNCTION tg_write_change_log('trip_id');
CREATE TRIGGER trg_maintenance_records_change_log AFTER INSERT OR UPDATE OR DELETE ON maintenance_records FOR EACH ROW EXECUTE FUNCTION tg_write_change_log('maintenance_id');
CREATE TRIGGER trg_incidents_change_log           AFTER INSERT OR UPDATE OR DELETE ON incidents           FOR EACH ROW EXECUTE FUNCTION tg_write_change_log('incident_id');

CREATE TRIGGER trg_depots_no_delete            BEFORE DELETE ON depots            FOR EACH ROW EXECUTE FUNCTION tg_forbid_hard_delete();
CREATE TRIGGER trg_vehicles_no_delete          BEFORE DELETE ON vehicles          FOR EACH ROW EXECUTE FUNCTION tg_forbid_hard_delete();
CREATE TRIGGER trg_drivers_no_delete           BEFORE DELETE ON drivers           FOR EACH ROW EXECUTE FUNCTION tg_forbid_hard_delete();
CREATE TRIGGER trg_customers_no_delete         BEFORE DELETE ON customers         FOR EACH ROW EXECUTE FUNCTION tg_forbid_hard_delete();
CREATE TRIGGER trg_routes_no_delete            BEFORE DELETE ON routes            FOR EACH ROW EXECUTE FUNCTION tg_forbid_hard_delete();
CREATE TRIGGER trg_service_providers_no_delete BEFORE DELETE ON service_providers FOR EACH ROW EXECUTE FUNCTION tg_forbid_hard_delete();


CREATE FUNCTION tg_keep_odometer_growing()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.odometer_km < OLD.odometer_km THEN
        RAISE EXCEPTION 'Пробіг авто % не може зменшитися: % -> % км',
            OLD.plate_number, OLD.odometer_km, NEW.odometer_km;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_vehicles_odometer_growing
BEFORE UPDATE OF odometer_km ON vehicles
FOR EACH ROW EXECUTE FUNCTION tg_keep_odometer_growing();


CREATE FUNCTION tg_sync_vehicle_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_reading INT := (to_jsonb(NEW) ->> TG_ARGV[0])::INT;
BEGIN
    UPDATE vehicles
    SET odometer_km = v_reading
    WHERE vehicle_id = NEW.vehicle_id
      AND odometer_km < v_reading;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_trips_sync_odometer
AFTER INSERT OR UPDATE OF status ON trips
FOR EACH ROW WHEN (NEW.status = 'completed')
EXECUTE FUNCTION tg_sync_vehicle_odometer('odometer_end');

CREATE TRIGGER trg_fuel_sync_odometer
AFTER INSERT ON fuel_transactions
FOR EACH ROW EXECUTE FUNCTION tg_sync_vehicle_odometer('odometer_km');


CREATE FUNCTION tg_check_trip()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_vehicle     vehicles;
    v_driver      drivers;
    v_driver_name TEXT;
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.status IN ('completed', 'cancelled') THEN
        RAISE EXCEPTION 'Рейс % уже закритий (%), змінювати його не можна', OLD.trip_number, OLD.status;
    END IF;

    IF TG_OP = 'UPDATE'
       AND NEW.vehicle_id = OLD.vehicle_id
       AND NEW.driver_id = OLD.driver_id
       AND NEW.planned_end = OLD.planned_end THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_vehicle FROM vehicles WHERE vehicle_id = NEW.vehicle_id;
    SELECT * INTO v_driver  FROM drivers  WHERE driver_id  = NEW.driver_id;
    v_driver_name := short_person_name(v_driver.last_name, v_driver.first_name, v_driver.middle_name);

    IF v_vehicle.deleted_at IS NOT NULL OR v_vehicle.status = 'decommissioned' THEN
        RAISE EXCEPTION 'Авто % недоступне для рейсів', v_vehicle.plate_number;
    END IF;
    IF v_driver.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'Водій % звільнений', v_driver_name;
    END IF;
    IF NOT driver_has_category(NEW.driver_id, NEW.vehicle_id) THEN
        RAISE EXCEPTION 'Водій % не має категорії для авто %', v_driver_name, v_vehicle.plate_number;
    END IF;
    IF v_driver.license_expires < NEW.planned_end::DATE THEN
        RAISE EXCEPTION 'Посвідчення водія % спливає % - раніше, ніж закінчиться рейс',
            v_driver_name, v_driver.license_expires;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_trips_check
BEFORE INSERT OR UPDATE ON trips
FOR EACH ROW EXECUTE FUNCTION tg_check_trip();


CREATE FUNCTION tg_check_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = NEW.vehicle_id AND deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Авто % в архіві', NEW.vehicle_id;
    END IF;
    IF EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = NEW.vehicle_id AND status = 'decommissioned') THEN
        RAISE EXCEPTION 'Авто % списане, закріпити водія не можна', NEW.vehicle_id;
    END IF;
    IF EXISTS (SELECT 1 FROM drivers WHERE driver_id = NEW.driver_id AND deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Водій % звільнений', NEW.driver_id;
    END IF;
    IF NOT driver_has_category(NEW.driver_id, NEW.vehicle_id) THEN
        RAISE EXCEPTION 'Водій % не має категорії для авто %', NEW.driver_id, NEW.vehicle_id;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_assignments_check
BEFORE INSERT OR UPDATE OF vehicle_id, driver_id ON vehicle_assignments
FOR EACH ROW EXECUTE FUNCTION tg_check_assignment();


CREATE FUNCTION tg_follow_maintenance_status()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_other_in_progress BOOLEAN;
BEGIN
    IF NEW.status = 'in_progress' THEN
        IF EXISTS (SELECT 1 FROM trips WHERE vehicle_id = NEW.vehicle_id AND status = 'in_progress') THEN
            RAISE EXCEPTION 'Авто % зараз у рейсі, почати ТО не можна', NEW.vehicle_id;
        END IF;

        UPDATE vehicles
        SET status = 'in_service'
        WHERE vehicle_id = NEW.vehicle_id
          AND status = 'active';

    ELSIF NEW.status IN ('completed', 'cancelled') THEN
        v_other_in_progress := EXISTS (
            SELECT 1
            FROM maintenance_records
            WHERE vehicle_id = NEW.vehicle_id
              AND status = 'in_progress'
              AND maintenance_id <> NEW.maintenance_id);

        IF NOT v_other_in_progress THEN
            UPDATE vehicles
            SET status = 'active'
            WHERE vehicle_id = NEW.vehicle_id
              AND status = 'in_service';
        END IF;
    END IF;

    RETURN NULL;
END $$;

CREATE TRIGGER trg_maintenance_follow_status
AFTER INSERT OR UPDATE OF status ON maintenance_records
FOR EACH ROW EXECUTE FUNCTION tg_follow_maintenance_status();


CREATE FUNCTION tg_lock_closed_maintenance_items()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_maintenance_id INT := COALESCE(NEW.maintenance_id, OLD.maintenance_id);
    v_status         maintenance_status;
BEGIN
    SELECT status INTO v_status
    FROM maintenance_records
    WHERE maintenance_id = v_maintenance_id;

    IF v_status IN ('completed', 'cancelled')
       AND current_setting('fleet.allow_closed_edit', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'ТО % уже закрите (%), рядки змінювати не можна', v_maintenance_id, v_status;
    END IF;

    RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER trg_maintenance_items_lock
BEFORE INSERT OR UPDATE OR DELETE ON maintenance_items
FOR EACH ROW EXECUTE FUNCTION tg_lock_closed_maintenance_items();
