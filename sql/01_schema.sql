DROP SCHEMA IF EXISTS fleet CASCADE;
CREATE SCHEMA fleet;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fleet_app') THEN
        CREATE ROLE fleet_app LOGIN PASSWORD 'fleet_app';
    END IF;
END $$;
SET search_path TO fleet, public;

CREATE EXTENSION IF NOT EXISTS pg_trgm    SCHEMA public;
CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA public;

CREATE TYPE user_role          AS ENUM ('admin', 'dispatcher', 'mechanic', 'fleet_manager');
CREATE TYPE vehicle_status     AS ENUM ('active', 'in_service', 'decommissioned');
CREATE TYPE trip_status        AS ENUM ('planned', 'in_progress', 'completed', 'cancelled');
CREATE TYPE maintenance_status AS ENUM ('scheduled', 'in_progress', 'completed', 'cancelled');
CREATE TYPE incident_type      AS ENUM ('accident', 'fine', 'breakdown', 'damage');
CREATE TYPE change_action      AS ENUM ('created', 'updated', 'deleted', 'archived', 'restored');

CREATE FUNCTION vin_is_valid(p_vin TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    c_weights CONSTANT INT[] := ARRAY[8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];
    c_letters CONSTANT TEXT  := 'ABCDEFGHJKLMNPRSTUVWXYZ';
    c_values  CONSTANT INT[] := ARRAY[1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 7, 9, 2, 3, 4, 5, 6, 7, 8, 9];
    v_sum     INT := 0;
    v_char    TEXT;
    v_digit   INT;
BEGIN
    IF p_vin !~ '^[A-HJ-NPR-Z0-9]{17}$' THEN
        RETURN FALSE;
    END IF;

    FOR i IN 1 .. 17 LOOP
        v_char  := substr(p_vin, i, 1);
        v_digit := CASE WHEN v_char ~ '[0-9]'
                        THEN v_char::INT
                        ELSE c_values[strpos(c_letters, v_char)]
                   END;
        v_sum   := v_sum + c_weights[i] * v_digit;
    END LOOP;

    RETURN substr(p_vin, 9, 1) = CASE WHEN v_sum % 11 = 10 THEN 'X' ELSE (v_sum % 11)::TEXT END;
END $$;

CREATE DOMAIN email_text   AS VARCHAR(150) CHECK (VALUE ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');
CREATE DOMAIN phone_text   AS VARCHAR(20)  CHECK (VALUE ~ '^\+380[0-9]{9}$');
CREATE DOMAIN code_text    AS VARCHAR(30)  CHECK (VALUE ~ '^[A-Z][A-Z0-9]*(-[A-Z0-9]+)*$');
CREATE DOMAIN vin_text     AS CHAR(17)     CHECK (vin_is_valid(VALUE));
CREATE DOMAIN plate_text   AS VARCHAR(8)   CHECK (VALUE ~ '^[ABCEHIKMOPTX]{2}[0-9]{4}[ABCEHIKMOPTX]{2}$');
CREATE DOMAIN money_amount AS NUMERIC(14,2) CHECK (VALUE >= 0);


CREATE TABLE app_users (
    user_id     INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    login       VARCHAR(40)  NOT NULL UNIQUE,
    full_name   VARCHAR(150) NOT NULL,
    role        user_role    NOT NULL,
    email       email_text   NOT NULL UNIQUE,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT ck_app_users_login CHECK (login ~ '^[a-z][a-z0-9.]{2,39}$')
);

CREATE TABLE cities (
    city_id  INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name     VARCHAR(100) NOT NULL,
    oblast   VARCHAR(100),

    CONSTRAINT uq_cities_name UNIQUE NULLS NOT DISTINCT (oblast, name)
);

CREATE TABLE fuel_types (
    fuel_type_id  INT         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code          VARCHAR(10) NOT NULL UNIQUE,
    title         VARCHAR(50) NOT NULL,
    unit          VARCHAR(5)  NOT NULL,

    CONSTRAINT ck_fuel_types_unit CHECK (unit IN ('l', 'kWh'))
);

CREATE TABLE license_categories (
    category     VARCHAR(3)   PRIMARY KEY,
    description  VARCHAR(150) NOT NULL,

    CONSTRAINT ck_license_categories_code
        CHECK (category IN ('A', 'A1', 'B', 'BE', 'C', 'C1', 'C1E', 'CE', 'D', 'D1', 'D1E', 'DE', 'T'))
);

CREATE TABLE vehicle_makes (
    make_id  INT         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name     VARCHAR(60) NOT NULL UNIQUE,
    country  VARCHAR(60)
);

CREATE TABLE vehicle_models (
    model_id             INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    make_id              INT          NOT NULL REFERENCES vehicle_makes,
    name                 VARCHAR(80)  NOT NULL,
    body_type            VARCHAR(20)  NOT NULL,
    fuel_type_id         INT          NOT NULL REFERENCES fuel_types,
    required_category    VARCHAR(3)   NOT NULL REFERENCES license_categories,
    payload_kg           INT          NOT NULL DEFAULT 0,
    seats                INT          NOT NULL DEFAULT 2,
    fuel_norm_per_100km  NUMERIC(5,2) NOT NULL,

    CONSTRAINT uq_vehicle_models_name  UNIQUE (make_id, name),
    CONSTRAINT ck_vehicle_models_body  CHECK (body_type IN ('tractor', 'truck', 'van', 'bus', 'pickup', 'car')),
    CONSTRAINT ck_vehicle_models_sizes CHECK (payload_kg >= 0 AND seats > 0 AND fuel_norm_per_100km > 0)
);

CREATE TABLE maintenance_types (
    maintenance_type_id  INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code                 code_text    NOT NULL UNIQUE,
    title                VARCHAR(100) NOT NULL,
    every_km             INT,
    every_days           INT,

    CONSTRAINT ck_maintenance_types_interval
        CHECK ((every_km > 0 OR every_km IS NULL)
           AND (every_days > 0 OR every_days IS NULL))
);


CREATE TABLE depots (
    depot_id     INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         code_text    NOT NULL,
    name         VARCHAR(150) NOT NULL,
    city_id      INT          NOT NULL REFERENCES cities,
    address      VARCHAR(200),
    phone        phone_text,
    capacity     INT,
    manager_id   INT          REFERENCES app_users,

    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by   INT          REFERENCES app_users,
    modified_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    modified_by  INT          REFERENCES app_users,
    deleted_at   TIMESTAMPTZ,
    deleted_by   INT          REFERENCES app_users,

    CONSTRAINT ck_depots_capacity CHECK (capacity > 0),
    CONSTRAINT ck_depots_deleted  CHECK (deleted_by IS NULL OR deleted_at IS NOT NULL)
);

CREATE TABLE vehicles (
    vehicle_id        INT            GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vin               vin_text       NOT NULL,
    plate_number      plate_text     NOT NULL,
    model_id          INT            NOT NULL REFERENCES vehicle_models,
    depot_id          INT            NOT NULL REFERENCES depots,
    manufacture_year  INT            NOT NULL,
    purchase_date     DATE,
    purchase_price    money_amount,
    odometer_km       INT            NOT NULL DEFAULT 0,
    status            vehicle_status NOT NULL DEFAULT 'active',
    color             VARCHAR(30),
    notes             TEXT,

    created_at        TIMESTAMPTZ    NOT NULL DEFAULT now(),
    created_by        INT            REFERENCES app_users,
    modified_at       TIMESTAMPTZ    NOT NULL DEFAULT now(),
    modified_by       INT            REFERENCES app_users,
    deleted_at        TIMESTAMPTZ,
    deleted_by        INT            REFERENCES app_users,

    CONSTRAINT ck_vehicles_year     CHECK (manufacture_year BETWEEN 1980 AND 2100),
    CONSTRAINT ck_vehicles_odometer CHECK (odometer_km >= 0),
    CONSTRAINT ck_vehicles_purchase CHECK (extract(YEAR FROM purchase_date) >= manufacture_year - 1),
    CONSTRAINT ck_vehicles_deleted  CHECK (deleted_by IS NULL OR deleted_at IS NOT NULL)
);

CREATE TABLE insurance_policies (
    policy_id      INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id     INT          NOT NULL REFERENCES vehicles,
    policy_type    VARCHAR(10)  NOT NULL,
    insurer        VARCHAR(150) NOT NULL,
    policy_number  VARCHAR(20)  NOT NULL UNIQUE,
    valid_during   DATERANGE    NOT NULL,
    premium        money_amount NOT NULL,

    CONSTRAINT ck_insurance_type   CHECK (policy_type IN ('osago', 'kasko')),
    CONSTRAINT ck_insurance_number CHECK (policy_number ~ '^[A-Z]{2}-[0-9]{9}$'),
    CONSTRAINT ck_insurance_period CHECK (NOT isempty(valid_during)
                                      AND NOT lower_inf(valid_during)
                                      AND NOT upper_inf(valid_during)),
    CONSTRAINT ex_insurance_overlap EXCLUDE USING gist (
        vehicle_id   WITH =,
        policy_type  WITH =,
        valid_during WITH &&
    )
);


CREATE TABLE drivers (
    driver_id        INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    last_name        VARCHAR(60)  NOT NULL,
    first_name       VARCHAR(60)  NOT NULL,
    middle_name      VARCHAR(60),
    birth_date       DATE         NOT NULL,
    phone            phone_text,
    email            email_text,
    license_number   VARCHAR(9)   NOT NULL,
    license_expires  DATE         NOT NULL,
    hired_on         DATE         NOT NULL DEFAULT CURRENT_DATE,
    depot_id         INT          NOT NULL REFERENCES depots,
    user_id          INT          UNIQUE REFERENCES app_users,

    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by       INT          REFERENCES app_users,
    modified_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    modified_by      INT          REFERENCES app_users,
    deleted_at       TIMESTAMPTZ,
    deleted_by       INT          REFERENCES app_users,

    CONSTRAINT ck_drivers_license CHECK (license_number ~ '^[A-Z]{3}[0-9]{6}$'),
    CONSTRAINT ck_drivers_adult   CHECK (hired_on >= birth_date + INTERVAL '18 years'),
    CONSTRAINT ck_drivers_deleted CHECK (deleted_by IS NULL OR deleted_at IS NOT NULL)
);

CREATE TABLE driver_license_categories (
    driver_id    INT        NOT NULL REFERENCES drivers,
    category     VARCHAR(3) NOT NULL REFERENCES license_categories,
    obtained_on  DATE,

    PRIMARY KEY (driver_id, category)
);

CREATE TABLE vehicle_assignments (
    assignment_id  INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id     INT          NOT NULL REFERENCES vehicles,
    driver_id      INT          NOT NULL REFERENCES drivers,
    active_during  DATERANGE    NOT NULL,
    note           VARCHAR(255),
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by     INT          REFERENCES app_users,

    CONSTRAINT ck_assignments_period CHECK (NOT isempty(active_during) AND NOT lower_inf(active_during)),
    CONSTRAINT ex_assignments_vehicle EXCLUDE USING gist (vehicle_id WITH =, active_during WITH &&),
    CONSTRAINT ex_assignments_driver  EXCLUDE USING gist (driver_id  WITH =, active_during WITH &&)
);


CREATE TABLE customers (
    customer_id     INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            VARCHAR(200) NOT NULL,
    tax_code        VARCHAR(10),
    city_id         INT          NOT NULL REFERENCES cities,
    address         VARCHAR(200),
    contact_person  VARCHAR(150),
    phone           phone_text,
    email           email_text,

    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      INT          REFERENCES app_users,
    modified_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    modified_by     INT          REFERENCES app_users,
    deleted_at      TIMESTAMPTZ,
    deleted_by      INT          REFERENCES app_users,

    CONSTRAINT ck_customers_tax_code CHECK (tax_code ~ '^([0-9]{8}|[0-9]{10})$'),
    CONSTRAINT ck_customers_deleted  CHECK (deleted_by IS NULL OR deleted_at IS NOT NULL)
);

CREATE TABLE routes (
    route_id         INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code             code_text    NOT NULL,
    name             VARCHAR(150) NOT NULL,
    from_city_id     INT          NOT NULL REFERENCES cities,
    to_city_id       INT          NOT NULL REFERENCES cities,
    distance_km      NUMERIC(8,1) NOT NULL,
    duration_hours   NUMERIC(5,1) NOT NULL,

    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by       INT          REFERENCES app_users,
    modified_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    modified_by      INT          REFERENCES app_users,
    deleted_at       TIMESTAMPTZ,
    deleted_by       INT          REFERENCES app_users,

    CONSTRAINT ck_routes_cities   CHECK (from_city_id <> to_city_id),
    CONSTRAINT ck_routes_size     CHECK (distance_km > 0 AND duration_hours > 0),
    CONSTRAINT ck_routes_deleted  CHECK (deleted_by IS NULL OR deleted_at IS NOT NULL)
);

CREATE TABLE trips (
    trip_id            INT           GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trip_number        VARCHAR(20)   NOT NULL UNIQUE,
    vehicle_id         INT           NOT NULL REFERENCES vehicles,
    driver_id          INT           NOT NULL REFERENCES drivers,
    route_id           INT           NOT NULL REFERENCES routes,
    customer_id        INT           REFERENCES customers,
    status             trip_status   NOT NULL DEFAULT 'planned',
    planned_start      TIMESTAMPTZ   NOT NULL,
    planned_end        TIMESTAMPTZ   NOT NULL,
    started_at         TIMESTAMPTZ,
    finished_at        TIMESTAMPTZ,
    odometer_start     INT,
    odometer_end       INT,
    distance_km        INT           GENERATED ALWAYS AS (odometer_end - odometer_start) STORED,
    cargo              VARCHAR(255),
    cargo_weight_kg    INT,
    freight_price      NUMERIC(12,2),
    cancel_reason      VARCHAR(255),

    created_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by         INT           REFERENCES app_users,
    modified_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    modified_by        INT           REFERENCES app_users,

    CONSTRAINT ck_trips_number   CHECK (trip_number ~ '^TR-[0-9]{4}-[0-9]{6}$'),
    CONSTRAINT ck_trips_plan     CHECK (planned_end > planned_start),
    CONSTRAINT ck_trips_cargo    CHECK (cargo_weight_kg >= 0 AND freight_price >= 0),
    CONSTRAINT ck_trips_odometer CHECK (odometer_end >= odometer_start),
    CONSTRAINT ck_trips_lifecycle CHECK (
        CASE status
            WHEN 'planned'     THEN started_at IS NULL AND finished_at IS NULL AND odometer_end IS NULL
            WHEN 'in_progress' THEN started_at IS NOT NULL AND finished_at IS NULL AND odometer_start IS NOT NULL
            WHEN 'completed'   THEN started_at IS NOT NULL AND finished_at IS NOT NULL
                                    AND finished_at >= started_at
                                    AND odometer_start IS NOT NULL AND odometer_end IS NOT NULL
            WHEN 'cancelled'   THEN finished_at IS NULL AND cancel_reason IS NOT NULL
        END
    ),
    CONSTRAINT ex_trips_vehicle_busy EXCLUDE USING gist (
        vehicle_id WITH =,
        tstzrange(planned_start, planned_end) WITH &&
    ) WHERE (status <> 'cancelled'),
    CONSTRAINT ex_trips_driver_busy EXCLUDE USING gist (
        driver_id WITH =,
        tstzrange(planned_start, planned_end) WITH &&
    ) WHERE (status <> 'cancelled')
);

CREATE TABLE fuel_transactions (
    fuel_tx_id    BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id    INT           NOT NULL REFERENCES vehicles,
    driver_id     INT           REFERENCES drivers,
    fuel_type_id  INT           NOT NULL REFERENCES fuel_types,
    filled_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    quantity      NUMERIC(8,2)  NOT NULL,
    unit_price    NUMERIC(8,2)  NOT NULL,
    total_cost    NUMERIC(12,2) GENERATED ALWAYS AS (round(quantity * unit_price, 2)) STORED,
    odometer_km   INT           NOT NULL,
    station       VARCHAR(150),
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by    INT           REFERENCES app_users,

    CONSTRAINT ck_fuel_amounts CHECK (quantity > 0 AND unit_price >= 0 AND odometer_km >= 0)
);


CREATE TABLE service_providers (
    provider_id  INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         VARCHAR(150) NOT NULL,
    city_id      INT          NOT NULL REFERENCES cities,
    address      VARCHAR(200),
    phone        phone_text,
    email        email_text,
    rating       NUMERIC(3,2),
    deleted_at   TIMESTAMPTZ,
    deleted_by   INT          REFERENCES app_users,

    CONSTRAINT ck_providers_rating  CHECK (rating BETWEEN 0 AND 5),
    CONSTRAINT ck_providers_deleted CHECK (deleted_by IS NULL OR deleted_at IS NOT NULL)
);

CREATE TABLE maintenance_records (
    maintenance_id       INT                GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id           INT                NOT NULL REFERENCES vehicles,
    maintenance_type_id  INT                NOT NULL REFERENCES maintenance_types,
    provider_id          INT                REFERENCES service_providers,
    status               maintenance_status NOT NULL DEFAULT 'scheduled',
    scheduled_on         DATE               NOT NULL,
    started_at           TIMESTAMPTZ,
    completed_at         TIMESTAMPTZ,
    odometer_km          INT,
    description          VARCHAR(255),

    created_at           TIMESTAMPTZ        NOT NULL DEFAULT now(),
    created_by           INT                REFERENCES app_users,
    modified_at          TIMESTAMPTZ        NOT NULL DEFAULT now(),
    modified_by          INT                REFERENCES app_users,

    CONSTRAINT ck_maintenance_odometer CHECK (odometer_km >= 0),
    CONSTRAINT ck_maintenance_lifecycle CHECK (
        CASE status
            WHEN 'scheduled'   THEN completed_at IS NULL
            WHEN 'cancelled'   THEN completed_at IS NULL
            WHEN 'in_progress' THEN started_at IS NOT NULL AND completed_at IS NULL
            WHEN 'completed'   THEN started_at IS NOT NULL AND completed_at IS NOT NULL
                                    AND completed_at >= started_at AND odometer_km IS NOT NULL
        END
    )
);

CREATE TABLE maintenance_items (
    item_id         INT           GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    maintenance_id  INT           NOT NULL REFERENCES maintenance_records ON DELETE CASCADE,
    kind            VARCHAR(10)   NOT NULL,
    description     VARCHAR(200)  NOT NULL,
    quantity        NUMERIC(10,2) NOT NULL,
    unit_price      NUMERIC(12,2) NOT NULL,
    line_total      NUMERIC(14,2) GENERATED ALWAYS AS (round(quantity * unit_price, 2)) STORED,

    CONSTRAINT ck_maintenance_items_kind    CHECK (kind IN ('labor', 'part')),
    CONSTRAINT ck_maintenance_items_amounts CHECK (quantity > 0 AND unit_price >= 0)
);

CREATE TABLE incidents (
    incident_id      INT           GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id       INT           NOT NULL REFERENCES vehicles,
    driver_id        INT           REFERENCES drivers,
    trip_id          INT           REFERENCES trips,
    type             incident_type NOT NULL,
    occurred_at      TIMESTAMPTZ   NOT NULL,
    location         VARCHAR(200),
    description      TEXT          NOT NULL,
    amount           money_amount  NOT NULL DEFAULT 0,
    driver_at_fault  BOOLEAN       NOT NULL DEFAULT FALSE,
    is_resolved      BOOLEAN       NOT NULL DEFAULT FALSE,

    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by       INT           REFERENCES app_users,
    modified_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    modified_by      INT           REFERENCES app_users,

    CONSTRAINT ck_incidents_fault CHECK (NOT driver_at_fault OR driver_id IS NOT NULL)
);


CREATE TABLE change_log (
    change_id   BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name  VARCHAR(63)   NOT NULL,
    record_id   INT           NOT NULL,
    action      change_action NOT NULL,
    changed_by  INT           REFERENCES app_users,
    changed_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TABLE change_log_fields (
    change_id   BIGINT       NOT NULL REFERENCES change_log ON DELETE CASCADE,
    field_name  VARCHAR(63)  NOT NULL,
    old_value   TEXT,
    new_value   TEXT,

    PRIMARY KEY (change_id, field_name)
);
