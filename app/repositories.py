import logging
from enum import Enum
from typing import Any, Optional, Sequence

from psycopg2 import sql
from psycopg2.extensions import connection as PgConnection
from psycopg2.extras import RealDictCursor

from .models import (
    ChangeRecord, DeletedRecord, Driver, DriverPerformance, DriverUpdate, ExpiringDocument,
    FuelConsumption, MaintenanceDue, MaintenanceRecord, MonthlyCost, NewAssignment, NewDriver,
    NewFuelTransaction, NewIncident, NewInsurancePolicy, NewMaintenance, NewMaintenanceItem,
    NewTrip, NewVehicle, Trip, TripStatus, Vehicle, VehicleCost, VehicleUpdate,
)

log = logging.getLogger(__name__)


def _db_value(value: Any) -> Any:
    return value.value if isinstance(value, Enum) else value


class BaseRepository:
    def __init__(self, conn: PgConnection):
        self._conn = conn

    def _query_view(self, view: str, where: Optional[dict[str, Any]] = None,
                    order_by: Optional[str] = None) -> list[dict]:
        where = where or {}
        query = sql.SQL("SELECT * FROM fleet.{}").format(sql.Identifier(view))
        if where:
            query += sql.SQL(" WHERE ") + sql.SQL(" AND ").join(
                sql.SQL("{} = %s").format(sql.Identifier(k)) for k in where)
        if order_by:
            # order_by - сталий фрагмент з коду репозиторію, не дані користувача
            query += sql.SQL(" ORDER BY ") + sql.SQL(order_by)
        params = [_db_value(v) for v in where.values()]

        with self._conn.cursor(cursor_factory=RealDictCursor) as cur:
            log.debug("%s %s", query.as_string(self._conn), params)
            cur.execute(query, params)
            return [dict(r) for r in cur.fetchall()]

    def _call(self, procedure: str, args: Sequence[Any] = (), out_params: int = 0) -> Optional[dict]:
        # out_params - кількість INOUT-параметрів у кінці процедури, їх значення повертаються словником
        placeholders = [sql.Placeholder()] * len(args) + [sql.SQL("NULL")] * out_params
        query = sql.SQL("CALL fleet.{}({})").format(sql.Identifier(procedure),
                                                   sql.SQL(", ").join(placeholders))
        params = [_db_value(a) for a in args]

        with self._conn.cursor(cursor_factory=RealDictCursor) as cur:
            log.debug("%s %s", query.as_string(self._conn), params)
            cur.execute(query, params)
            return dict(cur.fetchone()) if out_params else None


class VehicleRepository(BaseRepository):
    def get_all(self) -> list[Vehicle]:
        return [Vehicle.from_row(r) for r in self._query_view("v_active_vehicles", order_by="plate_number")]

    def get_by_id(self, vehicle_id: int) -> Optional[Vehicle]:
        rows = self._query_view("v_active_vehicles", {"vehicle_id": vehicle_id})
        return Vehicle.from_row(rows[0]) if rows else None

    def get_by_depot(self, depot_id: int) -> list[Vehicle]:
        rows = self._query_view("v_active_vehicles", {"depot_id": depot_id}, order_by="plate_number")
        return [Vehicle.from_row(r) for r in rows]

    def register(self, v: NewVehicle) -> int:
        out = self._call("sp_vehicle_register",
                         (v.vin, v.plate_number, v.model_id, v.depot_id, v.manufacture_year,
                          v.odometer_km, v.purchase_date, v.purchase_price, v.color),
                         out_params=1)
        return out["p_vehicle_id"]

    def update(self, u: VehicleUpdate) -> None:
        self._call("sp_vehicle_update", (u.vehicle_id, u.plate_number, u.depot_id, u.color, u.notes))

    def decommission(self, vehicle_id: int, reason: str) -> None:
        self._call("sp_vehicle_decommission", (vehicle_id, reason))

    def archive(self, vehicle_id: int) -> None:  # soft delete
        self._call("sp_vehicle_archive", (vehicle_id,))

    def restore(self, vehicle_id: int) -> None:
        self._call("sp_vehicle_restore", (vehicle_id,))

    def add_insurance(self, p: NewInsurancePolicy) -> int:
        out = self._call("sp_insurance_add",
                         (p.vehicle_id, p.policy_type, p.insurer, p.policy_number,
                          p.valid_from, p.valid_to, p.premium),
                         out_params=1)
        return out["p_policy_id"]


class DriverRepository(BaseRepository):
    def get_all(self) -> list[Driver]:
        return [Driver.from_row(r) for r in self._query_view("v_active_drivers", order_by="last_name")]

    def get_by_id(self, driver_id: int) -> Optional[Driver]:
        rows = self._query_view("v_active_drivers", {"driver_id": driver_id})
        return Driver.from_row(rows[0]) if rows else None

    def hire(self, d: NewDriver) -> int:
        out = self._call("sp_driver_hire",
                         (d.last_name, d.first_name, d.middle_name, d.birth_date, d.phone, d.email,
                          d.license_number, d.license_expires, d.depot_id, d.categories, d.hired_on),
                         out_params=1)
        return out["p_driver_id"]

    def update(self, u: DriverUpdate) -> None:
        self._call("sp_driver_update", (u.driver_id, u.phone, u.email, u.license_expires, u.depot_id))

    def replace_categories(self, driver_id: int, categories: list[str]) -> None:
        self._call("sp_driver_set_categories", (driver_id, categories))

    def dismiss(self, driver_id: int) -> None:
        self._call("sp_driver_dismiss", (driver_id,))

    def reinstate(self, driver_id: int) -> None:
        self._call("sp_driver_reinstate", (driver_id,))

    def assign(self, a: NewAssignment) -> int:
        out = self._call("sp_driver_assign", (a.vehicle_id, a.driver_id, a.start_date, a.note), out_params=1)
        return out["p_assignment_id"]


class TripRepository(BaseRepository):
    def get_by_id(self, trip_id: int) -> Optional[Trip]:
        rows = self._query_view("v_trips", {"trip_id": trip_id})
        return Trip.from_row(rows[0]) if rows else None

    def get_by_vehicle(self, vehicle_id: int) -> list[Trip]:
        rows = self._query_view("v_trips", {"vehicle_id": vehicle_id}, order_by="planned_start")
        return [Trip.from_row(r) for r in rows]

    def get_by_status(self, status: TripStatus) -> list[Trip]:
        rows = self._query_view("v_trips", {"status": status}, order_by="planned_start")
        return [Trip.from_row(r) for r in rows]

    def plan(self, t: NewTrip) -> tuple[int, str]:
        out = self._call("sp_trip_plan",
                         (t.vehicle_id, t.driver_id, t.route_id, t.customer_id, t.planned_start,
                          t.cargo, t.cargo_weight_kg, t.freight_price),
                         out_params=2)
        return out["p_trip_id"], out["p_trip_number"]

    def start(self, trip_id: int) -> None:
        self._call("sp_trip_start", (trip_id,))

    def finish(self, trip_id: int, odometer_end: int) -> None:
        self._call("sp_trip_finish", (trip_id, odometer_end))

    def cancel(self, trip_id: int, reason: str) -> None:
        self._call("sp_trip_cancel", (trip_id, reason))

    def add_fuel(self, f: NewFuelTransaction) -> int:
        out = self._call("sp_fuel_add",
                         (f.vehicle_id, f.driver_id, f.quantity, f.unit_price, f.odometer_km, f.station),
                         out_params=1)
        return out["p_fuel_tx_id"]

    def register_incident(self, i: NewIncident) -> int:
        out = self._call("sp_incident_register",
                         (i.vehicle_id, i.driver_id, i.trip_id, i.type, i.occurred_at, i.location,
                          i.description, i.amount, i.driver_at_fault),
                         out_params=1)
        return out["p_incident_id"]


class MaintenanceRepository(BaseRepository):
    def get_due(self) -> list[MaintenanceDue]:
        rows = self._query_view("v_maintenance_due", {"is_due": True}, order_by="plate_number")
        return [MaintenanceDue.from_row(r) for r in rows]

    def get_due_by_vehicle(self, vehicle_id: int) -> list[MaintenanceDue]:
        rows = self._query_view("v_maintenance_due", {"vehicle_id": vehicle_id}, order_by="maintenance_type_id")
        return [MaintenanceDue.from_row(r) for r in rows]

    def get_by_id(self, maintenance_id: int) -> Optional[MaintenanceRecord]:
        rows = self._query_view("v_maintenance_records", {"maintenance_id": maintenance_id})
        return MaintenanceRecord.from_row(rows[0]) if rows else None

    def get_by_vehicle(self, vehicle_id: int) -> list[MaintenanceRecord]:
        rows = self._query_view("v_maintenance_records", {"vehicle_id": vehicle_id}, order_by="scheduled_on")
        return [MaintenanceRecord.from_row(r) for r in rows]

    def schedule(self, m: NewMaintenance) -> int:
        out = self._call("sp_maintenance_schedule",
                         (m.vehicle_id, m.type, m.scheduled_on, m.provider_id, m.description),
                         out_params=1)
        return out["p_maintenance_id"]

    def start(self, maintenance_id: int) -> None:
        self._call("sp_maintenance_start", (maintenance_id,))

    def add_item(self, item: NewMaintenanceItem) -> int:
        out = self._call("sp_maintenance_add_item",
                         (item.maintenance_id, item.kind, item.description, item.quantity, item.unit_price),
                         out_params=1)
        return out["p_item_id"]

    def complete(self, maintenance_id: int) -> None:
        self._call("sp_maintenance_complete", (maintenance_id,))

    def cancel(self, maintenance_id: int) -> None:
        self._call("sp_maintenance_cancel", (maintenance_id,))


class ReportRepository(BaseRepository):
    def vehicle_costs(self) -> list[VehicleCost]:
        return [VehicleCost.from_row(r) for r in self._query_view("v_vehicle_costs", order_by="total_cost DESC")]

    def fuel_consumption(self) -> list[FuelConsumption]:
        rows = self._query_view("v_fuel_consumption", order_by="deviation_pct DESC")
        return [FuelConsumption.from_row(r) for r in rows]

    def expiring_documents(self) -> list[ExpiringDocument]:
        rows = self._query_view("v_expiring_documents", order_by="days_left")
        return [ExpiringDocument.from_row(r) for r in rows]

    def driver_performance(self) -> list[DriverPerformance]:
        rows = self._query_view("v_driver_performance", order_by="revenue DESC")
        return [DriverPerformance.from_row(r) for r in rows]

    def monthly_costs(self) -> list[MonthlyCost]:
        self._call("sp_reports_refresh")
        rows = self._query_view("mv_monthly_costs", order_by="month, depot_code")
        return [MonthlyCost.from_row(r) for r in rows]


class AuditRepository(BaseRepository):
    def history(self, table_name: str, record_id: int) -> list[ChangeRecord]:
        rows = self._query_view("v_audit_trail", {"table_name": table_name, "record_id": record_id},
                                order_by="change_id")
        return [ChangeRecord.from_row(r) for r in rows]

    def recycle_bin(self) -> list[DeletedRecord]:
        return [DeletedRecord.from_row(r) for r in self._query_view("v_deleted_records", order_by="deleted_at")]
