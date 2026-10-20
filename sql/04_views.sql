SET search_path TO fleet, public;

CREATE VIEW v_active_vehicles AS
SELECT v.vehicle_id,
       v.vin,
       v.plate_number,
       v.model_id,
       mk.name                                                  AS make_name,
       m.name                                                   AS model_name,
       m.body_type,
       ft.code                                                  AS fuel_type,
       m.required_category,
       m.payload_kg,
       v.depot_id,
       d.code                                                   AS depot_code,
       v.manufacture_year,
       v.odometer_km,
       v.status,
       v.color,
       v.notes,
       a.driver_id                                              AS current_driver_id,
       short_person_name(dr.last_name, dr.first_name, dr.middle_name) AS current_driver,
       v.modified_at,
       u.login                                                  AS modified_by_login
FROM vehicles                 v
JOIN vehicle_models           m  ON m.model_id      = v.model_id
JOIN vehicle_makes            mk ON mk.make_id      = m.make_id
JOIN fuel_types               ft ON ft.fuel_type_id = m.fuel_type_id
JOIN depots                   d  ON d.depot_id      = v.depot_id
LEFT JOIN vehicle_assignments a  ON a.vehicle_id    = v.vehicle_id AND a.active_during @> CURRENT_DATE
LEFT JOIN drivers             dr ON dr.driver_id    = a.driver_id
LEFT JOIN app_users           u  ON u.user_id       = v.modified_by
WHERE v.deleted_at IS NULL;

CREATE VIEW v_active_drivers AS
SELECT dr.driver_id,
       dr.last_name,
       dr.first_name,
       dr.middle_name,
       short_person_name(dr.last_name, dr.first_name, dr.middle_name) AS short_name,
       dr.birth_date,
       dr.phone,
       dr.email,
       dr.license_number,
       dr.license_expires,
       dr.license_expires - CURRENT_DATE                         AS license_days_left,
       cat.categories,
       dr.hired_on,
       dr.depot_id,
       d.code                                                    AS depot_code,
       a.vehicle_id                                              AS current_vehicle_id,
       v.plate_number                                            AS current_vehicle,
       dr.modified_at,
       u.login                                                   AS modified_by_login
FROM drivers                  dr
JOIN depots                   d ON d.depot_id   = dr.depot_id
LEFT JOIN vehicle_assignments a ON a.driver_id  = dr.driver_id AND a.active_during @> CURRENT_DATE
LEFT JOIN vehicles            v ON v.vehicle_id = a.vehicle_id
LEFT JOIN app_users           u ON u.user_id    = dr.modified_by
CROSS JOIN LATERAL (
    SELECT COALESCE(array_agg(c.category ORDER BY c.category), '{}') AS categories
    FROM driver_license_categories c
    WHERE c.driver_id = dr.driver_id
) cat
WHERE dr.deleted_at IS NULL;

CREATE VIEW v_current_assignments AS
SELECT a.assignment_id,
       a.vehicle_id,
       v.plate_number,
       a.driver_id,
       short_person_name(dr.last_name, dr.first_name, dr.middle_name) AS driver_name,
       lower(a.active_during)                                    AS assigned_from,
       upper(a.active_during)                                    AS assigned_to
FROM vehicle_assignments a
JOIN vehicles            v  ON v.vehicle_id = a.vehicle_id
JOIN drivers             dr ON dr.driver_id = a.driver_id
WHERE a.active_during @> CURRENT_DATE;


CREATE VIEW v_trips AS
SELECT t.trip_id,
       t.trip_number,
       t.status,
       t.vehicle_id,
       v.plate_number,
       t.driver_id,
       short_person_name(dr.last_name, dr.first_name, dr.middle_name) AS driver_name,
       t.route_id,
       r.name                                       AS route_name,
       from_city.name                               AS from_city,
       to_city.name                                 AS to_city,
       r.distance_km                                AS route_km,
       t.customer_id,
       c.name                                       AS customer_name,
       t.planned_start,
       t.planned_end,
       t.started_at,
       t.finished_at,
       t.odometer_start,
       t.odometer_end,
       t.distance_km,
       t.cargo,
       t.cargo_weight_kg,
       t.freight_price,
       CASE WHEN t.status = 'completed' THEN t.finished_at <= t.planned_end END AS on_time,
       t.cancel_reason,
       t.created_at,
       creator.login                                AS created_by_login,
       t.modified_at,
       editor.login                                 AS modified_by_login
FROM trips          t
JOIN vehicles       v         ON v.vehicle_id       = t.vehicle_id
JOIN drivers        dr        ON dr.driver_id       = t.driver_id
JOIN routes         r         ON r.route_id         = t.route_id
JOIN cities         from_city ON from_city.city_id  = r.from_city_id
JOIN cities         to_city   ON to_city.city_id    = r.to_city_id
LEFT JOIN customers c         ON c.customer_id      = t.customer_id
LEFT JOIN app_users creator   ON creator.user_id    = t.created_by
LEFT JOIN app_users editor    ON editor.user_id     = t.modified_by;

CREATE VIEW v_maintenance_due AS
SELECT v.vehicle_id,
       v.plate_number,
       v.status                                 AS vehicle_status,
       v.odometer_km,
       t.maintenance_type_id,
       t.code                                   AS maintenance_code,
       t.title                                  AS maintenance_title,
       due.last_km,
       due.last_on,
       due.due_km,
       due.due_on,
       due.due_km - v.odometer_km               AS km_left,
       due.due_on - CURRENT_DATE                AS days_left,
       COALESCE(due.due_km - v.odometer_km <= 1000, FALSE)
           OR COALESCE(due.due_on - CURRENT_DATE <= 14, FALSE) AS is_due,
       EXISTS (
           SELECT 1
           FROM maintenance_records mr
           WHERE mr.vehicle_id = v.vehicle_id
             AND mr.maintenance_type_id = t.maintenance_type_id
             AND mr.status IN ('scheduled', 'in_progress')
       )                                        AS is_scheduled
FROM vehicles                v
CROSS JOIN maintenance_types t
CROSS JOIN LATERAL next_maintenance_due(v.vehicle_id, t.maintenance_type_id) due
WHERE v.deleted_at IS NULL
  AND v.status <> 'decommissioned'
  AND (t.every_km IS NOT NULL OR t.every_days IS NOT NULL);

CREATE VIEW v_maintenance_records AS
SELECT mr.maintenance_id,
       mr.vehicle_id,
       v.plate_number,
       mr.maintenance_type_id,
       t.code                                                    AS maintenance_code,
       t.title                                                   AS maintenance_title,
       mr.provider_id,
       COALESCE(sp.name, 'Власними силами')                      AS provider_name,
       mr.status,
       mr.scheduled_on,
       mr.started_at,
       mr.completed_at,
       mr.odometer_km,
       mr.description,
       COALESCE(cost.items_count, 0)                             AS items_count,
       COALESCE(cost.labor, 0)::NUMERIC(14,2)                    AS labor_cost,
       COALESCE(cost.parts, 0)::NUMERIC(14,2)                    AS parts_cost,
       COALESCE(cost.labor + cost.parts, 0)::NUMERIC(14,2)       AS total_cost,
       mr.modified_at,
       u.login                                                   AS modified_by_login
FROM maintenance_records    mr
JOIN vehicles               v  ON v.vehicle_id          = mr.vehicle_id
JOIN maintenance_types      t  ON t.maintenance_type_id = mr.maintenance_type_id
LEFT JOIN service_providers sp ON sp.provider_id        = mr.provider_id
LEFT JOIN app_users         u  ON u.user_id             = mr.modified_by
LEFT JOIN LATERAL (
    SELECT COUNT(*)                                                  AS items_count,
           COALESCE(SUM(i.line_total) FILTER (WHERE i.kind = 'labor'), 0) AS labor,
           COALESCE(SUM(i.line_total) FILTER (WHERE i.kind = 'part'), 0)  AS parts
    FROM maintenance_items i
    WHERE i.maintenance_id = mr.maintenance_id
) cost ON TRUE;


CREATE VIEW v_fuel_consumption AS
SELECT v.vehicle_id,
       v.plate_number,
       mk.name || ' ' || m.name                                    AS model,
       m.fuel_norm_per_100km                                       AS norm_per_100km,
       actual.per_100km                                            AS actual_per_100km,
       round((actual.per_100km / m.fuel_norm_per_100km - 1) * 100, 1) AS deviation_pct
FROM vehicles       v
JOIN vehicle_models m  ON m.model_id = v.model_id
JOIN vehicle_makes  mk ON mk.make_id = m.make_id
CROSS JOIN LATERAL (
    SELECT vehicle_fuel_per_100km(v.vehicle_id, CURRENT_DATE - 90, CURRENT_DATE) AS per_100km
) actual
WHERE v.deleted_at IS NULL
  AND actual.per_100km IS NOT NULL;

CREATE VIEW v_vehicle_costs AS
WITH fuel AS (
    SELECT vehicle_id, SUM(total_cost) AS amount
    FROM fuel_transactions
    GROUP BY vehicle_id
),
service AS (
    SELECT mr.vehicle_id, SUM(i.line_total) AS amount
    FROM maintenance_records mr
    JOIN maintenance_items   i ON i.maintenance_id = mr.maintenance_id
    WHERE mr.status = 'completed'
    GROUP BY mr.vehicle_id
),
damage AS (
    SELECT vehicle_id, SUM(amount) AS amount
    FROM incidents
    GROUP BY vehicle_id
),
work AS (
    SELECT vehicle_id, SUM(freight_price) AS revenue, SUM(distance_km) AS km
    FROM trips
    WHERE status = 'completed'
    GROUP BY vehicle_id
)
SELECT v.vehicle_id,
       v.plate_number,
       d.code                                               AS depot_code,
       COALESCE(fuel.amount, 0)::NUMERIC(14,2)              AS fuel_cost,
       COALESCE(service.amount, 0)::NUMERIC(14,2)           AS maintenance_cost,
       COALESCE(damage.amount, 0)::NUMERIC(14,2)            AS incident_cost,
       vehicle_total_cost(v.vehicle_id)                     AS total_cost,
       COALESCE(work.revenue, 0)::NUMERIC(14,2)             AS revenue,
       COALESCE(work.km, 0)                                 AS km_driven,
       round(vehicle_total_cost(v.vehicle_id) / NULLIF(work.km, 0), 2) AS cost_per_km
FROM vehicles     v
JOIN depots       d ON d.depot_id = v.depot_id
LEFT JOIN fuel    USING (vehicle_id)
LEFT JOIN service USING (vehicle_id)
LEFT JOIN damage  USING (vehicle_id)
LEFT JOIN work    USING (vehicle_id)
WHERE v.deleted_at IS NULL;

CREATE VIEW v_expiring_documents AS
WITH current_policies AS (
    SELECT p.*,
           upper(p.valid_during) - 1 AS valid_to
    FROM insurance_policies p
    WHERE p.valid_during @> CURRENT_DATE
),
not_renewed AS (
    SELECT cp.*
    FROM current_policies cp
    WHERE NOT EXISTS (
        SELECT 1
        FROM insurance_policies next_policy
        WHERE next_policy.vehicle_id  = cp.vehicle_id
          AND next_policy.policy_type = cp.policy_type
          AND next_policy.policy_id  <> cp.policy_id
          AND lower(next_policy.valid_during) > cp.valid_to - 1
    )
)
SELECT 'insurance_' || nr.policy_type AS document_type,
       nr.policy_number               AS document_number,
       v.plate_number::TEXT           AS owner,
       nr.valid_to,
       nr.valid_to - CURRENT_DATE     AS days_left
FROM not_renewed nr
JOIN vehicles    v ON v.vehicle_id = nr.vehicle_id AND v.deleted_at IS NULL
WHERE nr.valid_to - CURRENT_DATE <= 30
UNION ALL
SELECT 'driver_license',
       dr.license_number,
       short_person_name(dr.last_name, dr.first_name, dr.middle_name),
       dr.license_expires,
       dr.license_expires - CURRENT_DATE
FROM drivers dr
WHERE dr.deleted_at IS NULL
  AND dr.license_expires - CURRENT_DATE <= 30;

CREATE VIEW v_driver_performance AS
WITH completed AS (
    SELECT driver_id,
           COUNT(*)                                     AS trips,
           SUM(distance_km)                             AS km,
           SUM(freight_price)                           AS revenue,
           COUNT(*) FILTER (WHERE finished_at <= planned_end) AS on_time
    FROM trips
    WHERE status = 'completed'
    GROUP BY driver_id
),
accidents AS (
    SELECT driver_id,
           COUNT(*)                                  AS total,
           COUNT(*) FILTER (WHERE driver_at_fault)   AS at_fault
    FROM incidents
    WHERE driver_id IS NOT NULL
    GROUP BY driver_id
)
SELECT dr.driver_id,
       short_person_name(dr.last_name, dr.first_name, dr.middle_name) AS driver_name,
       COALESCE(c.trips, 0)                                AS trips_completed,
       COALESCE(c.km, 0)                                   AS km_driven,
       COALESCE(c.revenue, 0)::NUMERIC(14,2)               AS revenue,
       round(100.0 * c.on_time / NULLIF(c.trips, 0), 1)    AS on_time_pct,
       COALESCE(a.total, 0)                                AS incidents,
       COALESCE(a.at_fault, 0)                             AS incidents_at_fault
FROM drivers        dr
LEFT JOIN completed c USING (driver_id)
LEFT JOIN accidents a USING (driver_id)
WHERE dr.deleted_at IS NULL;

CREATE MATERIALIZED VIEW mv_monthly_costs AS
WITH costs AS (
    SELECT vehicle_id, filled_at AS happened_at, total_cost AS fuel, 0 AS service, 0 AS damage
    FROM fuel_transactions
    UNION ALL
    SELECT mr.vehicle_id, mr.completed_at, 0, i.line_total, 0
    FROM maintenance_records mr
    JOIN maintenance_items   i ON i.maintenance_id = mr.maintenance_id
    WHERE mr.status = 'completed'
    UNION ALL
    SELECT vehicle_id, occurred_at, 0, 0, amount
    FROM incidents
)
SELECT date_trunc('month', c.happened_at)::DATE              AS month,
       d.code                                                AS depot_code,
       SUM(c.fuel)::NUMERIC(14,2)                            AS fuel_cost,
       SUM(c.service)::NUMERIC(14,2)                         AS maintenance_cost,
       SUM(c.damage)::NUMERIC(14,2)                          AS incident_cost,
       SUM(c.fuel + c.service + c.damage)::NUMERIC(14,2)     AS total_cost
FROM costs    c
JOIN vehicles v ON v.vehicle_id = c.vehicle_id
JOIN depots   d ON d.depot_id   = v.depot_id
GROUP BY 1, 2
WITH NO DATA;

CREATE UNIQUE INDEX ux_mv_monthly_costs ON mv_monthly_costs (month, depot_code);


CREATE VIEW v_audit_trail AS
SELECT cl.change_id,
       cl.changed_at,
       cl.table_name,
       cl.record_id,
       cl.action,
       u.login AS changed_by_login,
       (
           SELECT string_agg(format('%s: %s → %s',
                                    f.field_name,
                                    COALESCE(f.old_value, '∅'),
                                    COALESCE(f.new_value, '∅')),
                             '; ' ORDER BY f.field_name)
           FROM change_log_fields f
           WHERE f.change_id = cl.change_id
       )       AS changes
FROM change_log     cl
LEFT JOIN app_users u ON u.user_id = cl.changed_by;

CREATE VIEW v_deleted_records AS
WITH archived (entity, id, name, deleted_at, deleted_by) AS (
    SELECT 'vehicles', vehicle_id, plate_number::TEXT, deleted_at, deleted_by
    FROM vehicles WHERE deleted_at IS NOT NULL
    UNION ALL
    SELECT 'drivers', driver_id, short_person_name(last_name, first_name, middle_name), deleted_at, deleted_by
    FROM drivers WHERE deleted_at IS NOT NULL
    UNION ALL
    SELECT 'depots', depot_id, name, deleted_at, deleted_by
    FROM depots WHERE deleted_at IS NOT NULL
    UNION ALL
    SELECT 'customers', customer_id, name, deleted_at, deleted_by
    FROM customers WHERE deleted_at IS NOT NULL
    UNION ALL
    SELECT 'routes', route_id, name, deleted_at, deleted_by
    FROM routes WHERE deleted_at IS NOT NULL
    UNION ALL
    SELECT 'service_providers', provider_id, name, deleted_at, deleted_by
    FROM service_providers WHERE deleted_at IS NOT NULL
)
SELECT a.entity,
       a.id,
       a.name,
       a.deleted_at,
       u.login AS deleted_by_login
FROM archived       a
LEFT JOIN app_users u ON u.user_id = a.deleted_by;
