SET search_path TO fleet, public;

CREATE UNIQUE INDEX ux_vehicles_vin_active      ON vehicles  (vin)            WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_vehicles_plate_active    ON vehicles  (plate_number)   WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_depots_code_active       ON depots    (code)           WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_routes_code_active       ON routes    (code)           WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_drivers_license_active   ON drivers   (license_number) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_customers_tax_active     ON customers (tax_code)       WHERE deleted_at IS NULL AND tax_code IS NOT NULL;

CREATE INDEX ix_trips_vehicle_schedule ON trips (vehicle_id, planned_start DESC);
CREATE INDEX ix_trips_driver_schedule  ON trips (driver_id, planned_start DESC);
CREATE INDEX ix_trips_open             ON trips (status, planned_start) WHERE status IN ('planned', 'in_progress');

CREATE INDEX ix_maintenance_open ON maintenance_records (vehicle_id, maintenance_type_id)
    WHERE status IN ('scheduled', 'in_progress');
CREATE INDEX ix_maintenance_last_done ON maintenance_records (vehicle_id, maintenance_type_id, completed_at DESC)
    INCLUDE (odometer_km)
    WHERE status = 'completed';

CREATE INDEX ix_drivers_email_ci   ON drivers   (lower(email));
CREATE INDEX ix_customers_email_ci ON customers (lower(email));

CREATE INDEX gx_drivers_name_search ON drivers
    USING gin ((last_name || ' ' || first_name || ' ' || COALESCE(middle_name, '')) gin_trgm_ops);
CREATE INDEX gx_customers_name_search ON customers
    USING gin (name gin_trgm_ops);

CREATE INDEX sx_insurance_valid_during ON insurance_policies USING gist (valid_during);

CREATE INDEX bx_fuel_filled_at      ON fuel_transactions USING brin (filled_at);
CREATE INDEX bx_incidents_occurred  ON incidents         USING brin (occurred_at);
CREATE INDEX bx_change_log_changed  ON change_log        USING brin (changed_at);

CREATE INDEX hx_fuel_station ON fuel_transactions USING hash (station);

CREATE INDEX ix_change_log_record       ON change_log                (table_name, record_id);
CREATE INDEX ix_vehicles_model          ON vehicles                  (model_id);
CREATE INDEX ix_vehicles_depot          ON vehicles                  (depot_id);
CREATE INDEX ix_drivers_depot           ON drivers                   (depot_id);
CREATE INDEX ix_vehicle_models_make     ON vehicle_models            (make_id);
CREATE INDEX ix_trips_route             ON trips                     (route_id);
CREATE INDEX ix_trips_customer          ON trips                     (customer_id);
CREATE INDEX ix_fuel_vehicle_filled     ON fuel_transactions         (vehicle_id, filled_at);
CREATE INDEX ix_maintenance_items_owner ON maintenance_items         (maintenance_id);
CREATE INDEX ix_incidents_vehicle       ON incidents                 (vehicle_id);
CREATE INDEX ix_incidents_driver        ON incidents                 (driver_id) WHERE driver_id IS NOT NULL;
CREATE INDEX ix_license_category        ON driver_license_categories (category);
CREATE INDEX ix_customers_city          ON customers                 (city_id);
CREATE INDEX ix_depots_city             ON depots                    (city_id);

ALTER TABLE fuel_transactions CLUSTER ON ix_fuel_vehicle_filled;
