from dataclasses import dataclass, field, fields
from datetime import date, datetime
from decimal import Decimal
from enum import Enum
from typing import Any, Optional, Union, get_args, get_origin, get_type_hints


# Значення в БД + підпис українською для виводу
class DbEnum(Enum):
    def __new__(cls, db_value: str, label: str):
        member = object.__new__(cls)
        member._value_ = db_value
        member.label = label
        return member

    def __str__(self) -> str:
        return self.label


class VehicleStatus(DbEnum):
    ACTIVE = ("active", "на лінії")
    IN_SERVICE = ("in_service", "на ТО")
    DECOMMISSIONED = ("decommissioned", "списане")


class TripStatus(DbEnum):
    PLANNED = ("planned", "заплановано")
    IN_PROGRESS = ("in_progress", "у дорозі")
    COMPLETED = ("completed", "завершено")
    CANCELLED = ("cancelled", "скасовано")


class MaintenanceStatus(DbEnum):
    SCHEDULED = ("scheduled", "заплановано")
    IN_PROGRESS = ("in_progress", "у роботі")
    COMPLETED = ("completed", "завершено")
    CANCELLED = ("cancelled", "скасовано")


class MaintenanceTypeCode(DbEnum):
    TO1 = ("TO1", "ТО-1")
    TO2 = ("TO2", "ТО-2")
    TIRES = ("TIRES", "шини")
    REPAIR = ("REPAIR", "ремонт")


class MaintenanceItemKind(DbEnum):
    LABOR = ("labor", "роботи")
    PART = ("part", "запчастини")


class PolicyType(DbEnum):
    OSAGO = ("osago", "ОСЦПВ")
    KASKO = ("kasko", "КАСКО")


class IncidentType(DbEnum):
    ACCIDENT = ("accident", "ДТП")
    FINE = ("fine", "штраф")
    BREAKDOWN = ("breakdown", "поломка")
    DAMAGE = ("damage", "пошкодження")


class DocumentType(DbEnum):
    INSURANCE_OSAGO = ("insurance_osago", "ОСЦПВ")
    INSURANCE_KASKO = ("insurance_kasko", "КАСКО")
    DRIVER_LICENSE = ("driver_license", "посвідчення")


class ChangeAction(DbEnum):
    CREATED = ("created", "створено")
    UPDATED = ("updated", "змінено")
    DELETED = ("deleted", "видалено")
    ARCHIVED = ("archived", "в архів")
    RESTORED = ("restored", "відновлено")


def _enum_type(hint: Any) -> Optional[type]:
    # Optional[X] розгортається до X
    if get_origin(hint) is Union:
        hint = next(arg for arg in get_args(hint) if arg is not type(None))
    return hint if isinstance(hint, type) and issubclass(hint, DbEnum) else None


def _from_row(cls, row: dict[str, Any]):
    # колонки view, яких немає в моделі, пропускаються; enum-колонки перетворюються з тексту
    hints = get_type_hints(cls)
    values = {}
    for f in fields(cls):
        if f.name not in row:
            continue
        value = row[f.name]
        enum_type = _enum_type(hints[f.name])
        values[f.name] = enum_type(value) if enum_type and value is not None else value
    return cls(**values)


# ---------- Рядки view ----------

@dataclass
class Vehicle:
    vehicle_id: int
    vin: str
    plate_number: str
    model_id: int
    make_name: str
    model_name: str
    fuel_type: str
    depot_id: int
    depot_code: str
    manufacture_year: int
    odometer_km: int
    status: VehicleStatus
    color: Optional[str] = None
    notes: Optional[str] = None
    current_driver_id: Optional[int] = None
    current_driver: Optional[str] = None
    modified_at: Optional[datetime] = None
    modified_by_login: Optional[str] = None

    from_row = classmethod(_from_row)


@dataclass
class Driver:
    driver_id: int
    last_name: str
    first_name: str
    middle_name: Optional[str]
    short_name: str
    birth_date: date
    phone: Optional[str]
    email: Optional[str]
    license_number: str
    license_expires: date
    license_days_left: int
    categories: list[str]
    hired_on: date
    depot_id: int
    depot_code: str
    current_vehicle_id: Optional[int] = None
    current_vehicle: Optional[str] = None
    modified_at: Optional[datetime] = None
    modified_by_login: Optional[str] = None

    from_row = classmethod(_from_row)


@dataclass
class Trip:
    trip_id: int
    trip_number: str
    status: TripStatus
    vehicle_id: int
    plate_number: str
    driver_id: int
    driver_name: str
    route_name: str
    customer_name: Optional[str]
    planned_start: datetime
    planned_end: datetime
    started_at: Optional[datetime] = None
    finished_at: Optional[datetime] = None
    on_time: Optional[bool] = None
    odometer_start: Optional[int] = None
    odometer_end: Optional[int] = None
    distance_km: Optional[int] = None
    cargo: Optional[str] = None
    cargo_weight_kg: Optional[int] = None
    freight_price: Optional[Decimal] = None
    created_by_login: Optional[str] = None
    modified_by_login: Optional[str] = None

    from_row = classmethod(_from_row)


@dataclass
class MaintenanceDue:
    vehicle_id: int
    plate_number: str
    vehicle_status: VehicleStatus
    odometer_km: int
    maintenance_code: MaintenanceTypeCode
    maintenance_title: str
    due_km: Optional[int]
    km_left: Optional[int]
    due_on: Optional[date]
    days_left: Optional[int]
    is_due: bool
    is_scheduled: bool

    from_row = classmethod(_from_row)


@dataclass
class MaintenanceRecord:
    maintenance_id: int
    vehicle_id: int
    plate_number: str
    maintenance_code: MaintenanceTypeCode
    maintenance_title: str
    provider_name: Optional[str]
    status: MaintenanceStatus
    scheduled_on: date
    started_at: Optional[datetime]
    completed_at: Optional[datetime]
    odometer_km: Optional[int]
    items_count: int
    labor_cost: Decimal
    parts_cost: Decimal
    total_cost: Decimal
    modified_by_login: Optional[str] = None

    from_row = classmethod(_from_row)


@dataclass
class VehicleCost:
    vehicle_id: int
    plate_number: str
    depot_code: str
    fuel_cost: Decimal
    maintenance_cost: Decimal
    incident_cost: Decimal
    total_cost: Decimal
    revenue: Decimal
    km_driven: int
    cost_per_km: Optional[Decimal]

    from_row = classmethod(_from_row)


@dataclass
class FuelConsumption:
    vehicle_id: int
    plate_number: str
    model: str
    norm_per_100km: Decimal
    actual_per_100km: Optional[Decimal]
    deviation_pct: Optional[Decimal]

    from_row = classmethod(_from_row)


@dataclass
class ExpiringDocument:
    document_type: DocumentType
    document_number: str
    owner: str
    valid_to: date
    days_left: int

    from_row = classmethod(_from_row)


@dataclass
class DriverPerformance:
    driver_id: int
    driver_name: str
    trips_completed: int
    km_driven: int
    revenue: Decimal
    on_time_pct: Optional[Decimal]
    incidents: int
    incidents_at_fault: int

    from_row = classmethod(_from_row)


@dataclass
class MonthlyCost:
    month: date
    depot_code: str
    fuel_cost: Decimal
    maintenance_cost: Decimal
    incident_cost: Decimal
    total_cost: Decimal

    from_row = classmethod(_from_row)


@dataclass
class ChangeRecord:
    change_id: int
    changed_at: datetime
    changed_by_login: Optional[str]
    table_name: str
    record_id: int
    action: ChangeAction
    changes: Optional[str]

    from_row = classmethod(_from_row)


@dataclass
class DeletedRecord:
    entity: str
    id: int
    name: str
    deleted_at: datetime
    deleted_by_login: Optional[str]

    from_row = classmethod(_from_row)


# ---------- Дані для процедур ----------

@dataclass
class NewVehicle:
    vin: str
    plate_number: str
    model_id: int
    depot_id: int
    manufacture_year: int
    odometer_km: int = 0
    purchase_date: Optional[date] = None
    purchase_price: Optional[Decimal] = None
    color: Optional[str] = None


@dataclass
class VehicleUpdate:
    # None - поле не змінюється
    vehicle_id: int
    plate_number: Optional[str] = None
    depot_id: Optional[int] = None
    color: Optional[str] = None
    notes: Optional[str] = None


@dataclass
class NewInsurancePolicy:
    vehicle_id: int
    policy_type: PolicyType
    insurer: str
    policy_number: str
    valid_from: date
    valid_to: date
    premium: Decimal


@dataclass
class NewDriver:
    last_name: str
    first_name: str
    middle_name: Optional[str]
    birth_date: date
    phone: Optional[str]
    email: Optional[str]
    license_number: str
    license_expires: date
    depot_id: int
    categories: list[str] = field(default_factory=list)
    hired_on: date = field(default_factory=date.today)


@dataclass
class DriverUpdate:
    driver_id: int
    phone: Optional[str] = None
    email: Optional[str] = None
    license_expires: Optional[date] = None
    depot_id: Optional[int] = None


@dataclass
class NewAssignment:
    vehicle_id: int
    driver_id: int
    start_date: date = field(default_factory=date.today)
    note: Optional[str] = None


@dataclass
class NewTrip:
    vehicle_id: int
    route_id: int
    planned_start: datetime
    driver_id: Optional[int] = None
    customer_id: Optional[int] = None
    cargo: Optional[str] = None
    cargo_weight_kg: Optional[int] = None
    freight_price: Optional[Decimal] = None


@dataclass
class NewFuelTransaction:
    vehicle_id: int
    quantity: Decimal
    unit_price: Decimal
    odometer_km: int
    driver_id: Optional[int] = None
    station: Optional[str] = None


@dataclass
class NewIncident:
    vehicle_id: int
    type: IncidentType
    description: str
    driver_id: Optional[int] = None
    trip_id: Optional[int] = None
    occurred_at: Optional[datetime] = None
    location: Optional[str] = None
    amount: Decimal = Decimal("0")
    driver_at_fault: bool = False


@dataclass
class NewMaintenance:
    vehicle_id: int
    type: MaintenanceTypeCode
    scheduled_on: date = field(default_factory=date.today)
    provider_id: Optional[int] = None
    description: Optional[str] = None


@dataclass
class NewMaintenanceItem:
    maintenance_id: int
    kind: MaintenanceItemKind
    description: str
    quantity: Decimal
    unit_price: Decimal
