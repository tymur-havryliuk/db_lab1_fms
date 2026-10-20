import logging
import os
import random
import sys
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from typing import Any, Optional, Sequence
from zoneinfo import ZoneInfo

from psycopg2 import Error as DbError

from .models import (
    MaintenanceItemKind, MaintenanceTypeCode, NewAssignment, NewDriver, NewFuelTransaction,
    NewInsurancePolicy, NewMaintenance, NewMaintenanceItem, NewTrip, NewVehicle, PolicyType,
    VehicleUpdate,
)
from .unit_of_work import UnitOfWork

# ---------- Дані з 07_seed.sql ----------

ADMIN = 1
DISPATCHER = 2
MECHANIC = 3
FLEET_MANAGER = 4

DEPOT_KYIV = 1
DEPOT_LVIV = 2

MODEL_MAN_TGL = 3
MODEL_RENAULT_MASTER = 5

ROUTE_KYIV_ZHYTOMYR = 5
CUSTOMER_NOVA_AGRO = 1
PROVIDER_LVIV = 2

VEHICLE_BC3003AM = 3
PLANNED_TRIP_BC3003AM = 16

KYIV = ZoneInfo("Europe/Kyiv")
HEADER_WIDTH = 76
TRIP_DISTANCE_KM = 146


# Що створив перший сценарій і використовують наступні
@dataclass
class DemoContext:
    vehicle_id: Optional[int] = None
    driver_id: Optional[int] = None
    trip_id: Optional[int] = None


# ---------- Унікальні коди, щоб демо можна було запускати повторно ----------

VIN_LETTERS = "ABCDEFGHJKLMNPRSTUVWXYZ"
VIN_LETTER_VALUES = [1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 7, 9, 2, 3, 4, 5, 6, 7, 8, 9]
VIN_WEIGHTS = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]
PLATE_LETTERS = "ABCEHIKMOPTX"


def random_digits(count: int) -> str:
    return "".join(random.choice("0123456789") for _ in range(count))


def vin(manufacturer_and_model: str) -> str:
    # контрольна цифра на 9-й позиції за ISO 3779
    chars = list(manufacturer_and_model + "0" + random_digits(8))
    total = sum(weight * (int(c) if c.isdigit() else VIN_LETTER_VALUES[VIN_LETTERS.index(c)])
                for weight, c in zip(VIN_WEIGHTS, chars))
    remainder = total % 11
    chars[8] = "X" if remainder == 10 else str(remainder)
    return "".join(chars)


def plate(region: str) -> str:
    return region + random_digits(4) + random.choice(PLATE_LETTERS) + random.choice(PLATE_LETTERS)


def license_number(series: str) -> str:
    return series + random_digits(6)


def policy_number(series: str) -> str:
    return series + "-" + random_digits(9)


# ---------- Тестові дані ----------

def new_renault_master() -> NewVehicle:
    return NewVehicle(vin=vin("VF1FL000"), plate_number=plate("AA"), model_id=MODEL_RENAULT_MASTER,
                      depot_id=DEPOT_KYIV, manufacture_year=2023, odometer_km=12_000, color="білий")


def new_man_tgl() -> NewVehicle:
    return NewVehicle(vin=vin("WMA13XZZ"), plate_number=plate("BC"), model_id=MODEL_MAN_TGL,
                      depot_id=DEPOT_LVIV, manufacture_year=2023, odometer_km=500, color="білий")


def add_years(day: date, years: int) -> date:
    try:
        return day.replace(year=day.year + years)
    except ValueError:  # 29 лютого
        return day.replace(year=day.year + years, day=28)


def yearly_osago(vehicle_id: int, valid_from: date) -> NewInsurancePolicy:
    valid_to = add_years(valid_from, 1) - timedelta(days=1)
    return NewInsurancePolicy(vehicle_id=vehicle_id, policy_type=PolicyType.OSAGO, insurer="СК «Оберіг»",
                              policy_number=policy_number("EP"), valid_from=valid_from, valid_to=valid_to,
                              premium=Decimal("3200.00"))


def driver_honcharenko(today: date) -> NewDriver:
    return NewDriver(last_name="Гончаренко", first_name="Тарас", middle_name="Ігорович",
                     birth_date=date(1992, 2, 17), phone="+380501112209",
                     email="t.honcharenko@fleet.example.com", license_number=license_number("BXA"),
                     license_expires=add_years(today, 5), depot_id=DEPOT_KYIV,
                     categories=["B", "C"], hired_on=today)


def trip_to_zhytomyr(vehicle_id: int, start: datetime, cargo: str, weight_kg: int, price: str) -> NewTrip:
    return NewTrip(vehicle_id=vehicle_id, route_id=ROUTE_KYIV_ZHYTOMYR, customer_id=CUSTOMER_NOVA_AGRO,
                   planned_start=start, cargo=cargo, cargo_weight_kg=weight_kg, freight_price=Decimal(price))


def oil_change_items(maintenance_id: int) -> list[NewMaintenanceItem]:
    return [
        NewMaintenanceItem(maintenance_id, MaintenanceItemKind.PART, "Моторна олива 10W-40, л",
                           Decimal("40"), Decimal("285.00")),
        NewMaintenanceItem(maintenance_id, MaintenanceItemKind.PART, "Комплект фільтрів",
                           Decimal("1"), Decimal("6800.00")),
        NewMaintenanceItem(maintenance_id, MaintenanceItemKind.LABOR, "Роботи ТО-1, год",
                           Decimal("3"), Decimal("950.00")),
    ]


def kyiv_today() -> date:
    return datetime.now(KYIV).date()


def kyiv_time(day: date, hour: int) -> datetime:
    return datetime.combine(day, time(hour), tzinfo=KYIV)


# ---------- Вивід ----------

def title(number: int, text: str) -> None:
    header = f"=== {number}. {text} "
    print()
    print(header + "=" * max(0, HEADER_WIDTH - len(header)))


def say(*parts: Any) -> None:
    print("  ", *parts)


def hm(moment: datetime) -> str:
    return moment.astimezone(KYIV).strftime("%d.%m %H:%M")


def yes_no(value: Optional[bool]) -> str:
    return "так" if value else "ні"


def print_table(headers: Sequence[str], rows: Sequence[Sequence[Any]]) -> None:
    # числові колонки вирівнюються праворуч, None виводиться як "-"
    def is_number(value: Any) -> bool:
        return isinstance(value, (int, float, Decimal)) and not isinstance(value, bool)

    cells = [["-" if v is None else str(v) for v in row] for row in rows]
    widths = [max([len(h)] + [len(row[i]) for row in cells]) for i, h in enumerate(headers)]
    numeric = [any(is_number(row[i]) for row in rows) for i in range(len(headers))]

    def line(values: Sequence[str], align: Sequence[bool]) -> str:
        parts = [v.rjust(w) if right else v.ljust(w) for v, w, right in zip(values, widths, align)]
        return "   " + "  ".join(parts).rstrip()

    print(line(headers, [False] * len(headers)))
    print("   " + "  ".join("─" * w for w in widths))
    if not rows:
        print("   (немає даних)")
    for row in cells:
        print(line(row, numeric))


# ---------- 1. Нове авто, новий водій, закріплення і рейс в одній транзакції ----------

def register_vehicle(ctx: DemoContext) -> None:
    today = kyiv_today()

    with UnitOfWork(user_id=FLEET_MANAGER) as uow:
        vehicle_id = uow.vehicles.register(new_renault_master())
        uow.vehicles.add_insurance(yearly_osago(vehicle_id, today))

        driver_id = uow.drivers.hire(driver_honcharenko(today))
        uow.drivers.assign(NewAssignment(vehicle_id, driver_id, start_date=today,
                                         note="Закріплення за новим авто"))

        trip_id, _ = uow.trips.plan(trip_to_zhytomyr(
            vehicle_id, kyiv_time(today + timedelta(days=1), 8), "Посівний матеріал", 1200, "5400.00"))
        uow.commit()

        v = uow.vehicles.get_by_id(vehicle_id)
        say(f"авто {v.plate_number}: {v.make_name} {v.model_name}, депо {v.depot_code}, "
            f"пробіг {v.odometer_km} км, водій {v.current_driver}")
        d = uow.drivers.get_by_id(driver_id)
        say(f"водій {d.short_name}: категорії [{', '.join(d.categories)}], посвідчення до {d.license_expires}")
        t = uow.trips.get_by_id(trip_id)
        say(f"рейс {t.trip_number}: {t.route_name}, {hm(t.planned_start)} → {hm(t.planned_end)}, "
            f"{t.status}, створив {t.created_by_login}")

    ctx.vehicle_id, ctx.driver_id, ctx.trip_id = vehicle_id, driver_id, trip_id


# ---------- 2. Відкат: архівація авто із запланованим рейсом, savepoint ----------

def rollback(ctx: DemoContext) -> None:
    vehicle_id = ctx.vehicle_id

    with UnitOfWork(user_id=FLEET_MANAGER) as uow:
        try:
            uow.vehicles.update(VehicleUpdate(vehicle_id, depot_id=DEPOT_LVIV, notes="Передано у Львів"))
            say("депо змінено в транзакції, ще не зафіксовано")
            uow.vehicles.archive(vehicle_id)  # відмова: в авто є запланований рейс
            uow.commit()
        except DbError as e:
            say("БД відмовила:", e.diag.message_primary)
            uow.rollback()
        say("депо після rollback:", uow.vehicles.get_by_id(vehicle_id).depot_code)

        uow.vehicles.update(VehicleUpdate(vehicle_id, notes="Перевірено диспетчерською"))
        uow.savepoint("before_trip")
        try:
            day = kyiv_today() + timedelta(days=4)
            # відмова: 5 т більше за вантажопідйомність Renault Master
            uow.trips.plan(trip_to_zhytomyr(vehicle_id, kyiv_time(day, 8), "Металопрокат", 5000, "9000.00"))
        except DbError as e:
            say("БД відмовила:", e.diag.message_primary)
            uow.rollback_to("before_trip")
        uow.commit()
        say("примітка збережена попри відкат кроку:", uow.vehicles.get_by_id(vehicle_id).notes)


# ---------- 3. Рейс і заправка оновлюють пробіг; ТО знімає авто з лінії ----------

def trip_and_maintenance(ctx: DemoContext) -> None:
    vehicle_id, trip_id = ctx.vehicle_id, ctx.trip_id

    with UnitOfWork(user_id=DISPATCHER) as uow:
        uow.trips.start(trip_id)
        uow.commit()

        started = uow.trips.get_by_id(trip_id)
        say(f"{started.trip_number} виїхав: {started.status}, одометр на старті {started.odometer_start}")

        odometer_at_finish = started.odometer_start + TRIP_DISTANCE_KM
        uow.trips.finish(trip_id, odometer_at_finish)
        uow.trips.add_fuel(NewFuelTransaction(vehicle_id, Decimal("16.50"), Decimal("54.30"),
                                              odometer_at_finish, station="WOG, Житомир, траса М-06"))
        uow.commit()

        t = uow.trips.get_by_id(trip_id)
        say(f"{t.trip_number}: {t.status}, пробіг рейсу {t.distance_km} км, "
            f"вчасно: {yes_no(t.on_time)}, змінив {t.modified_by_login}")
        say(f"пробіг авто {t.plate_number} тепер {uow.vehicles.get_by_id(vehicle_id).odometer_km} км")

    with UnitOfWork(user_id=MECHANIC) as uow:
        vehicle_id = VEHICLE_BC3003AM
        print_table(["Авто", "ТО", "Лишилось км", "Лишилось днів", "Час на ТО"],
                    [(d.plate_number, d.maintenance_code, d.km_left, d.days_left, "так" if d.is_due else "")
                     for d in uow.maintenance.get_due_by_vehicle(vehicle_id)])

        maintenance_id = uow.maintenance.schedule(NewMaintenance(
            vehicle_id, MaintenanceTypeCode.TO1, scheduled_on=kyiv_today(), provider_id=PROVIDER_LVIV,
            description="ТО-1 за пробігом"))
        uow.maintenance.start(maintenance_id)
        uow.commit()
        say("статус авто після початку ТО:", uow.vehicles.get_by_id(vehicle_id).status)

        try:
            uow.trips.start(PLANNED_TRIP_BC3003AM)  # відмова: авто на ТО
            uow.commit()
        except DbError as e:
            say("БД відмовила:", e.diag.message_primary)
            uow.rollback()

        for item in oil_change_items(maintenance_id):
            uow.maintenance.add_item(item)
        uow.maintenance.complete(maintenance_id)
        uow.commit()

        r = uow.maintenance.get_by_id(maintenance_id)
        say(f"{r.plate_number} {r.maintenance_code} у «{r.provider_name}»: {r.status}, "
            f"роботи {r.labor_cost} + запчастини {r.parts_cost} = {r.total_cost} грн, пробіг {r.odometer_km}")

        next_due = uow.maintenance.get_due_by_vehicle(vehicle_id)[0]
        say(f"авто знову {uow.vehicles.get_by_id(vehicle_id).status}, до наступного "
            f"{next_due.maintenance_code}: {next_due.km_left} км / {next_due.days_left} дн.")


# ---------- 4. Архівація (soft delete), відновлення та журнал змін ----------

def soft_delete(ctx: DemoContext) -> None:
    with UnitOfWork(user_id=ADMIN) as uow:
        vehicle_id = uow.vehicles.register(new_man_tgl())
        uow.commit()

        uow.vehicles.update(VehicleUpdate(vehicle_id, color="сірий"))
        uow.commit()

        uow.vehicles.archive(vehicle_id)
        uow.commit()
        say("серед активних:", uow.vehicles.get_by_id(vehicle_id) is not None)
        say("в архіві:", [f"{r.entity} {r.name}" for r in uow.audit.recycle_bin()])

        uow.vehicles.restore(vehicle_id)
        uow.commit()
        say("після відновлення серед активних:", uow.vehicles.get_by_id(vehicle_id) is not None)

        print_table(["Коли", "Дія", "Хто", "Що змінилось"],
                    [(hm(c.changed_at), c.action, c.changed_by_login, c.changes)
                     for c in uow.audit.history("vehicles", vehicle_id)])


# ---------- 5. Звіти з розрізів даних ----------

def reports(ctx: DemoContext) -> None:
    with UnitOfWork(user_id=ADMIN) as uow:
        say("Потребують ТО:")
        print_table(["Авто", "ТО", "Лишилось км", "Лишилось днів", "Заплановано"],
                    [(d.plate_number, d.maintenance_code, d.km_left, d.days_left, "так" if d.is_scheduled else "")
                     for d in uow.maintenance.get_due()])

        say("Документи, що спливають:")
        print_table(["Документ", "Номер", "Власник", "Дійсний до", "Днів"],
                    [(d.document_type, d.document_number, d.owner, d.valid_to, d.days_left)
                     for d in uow.reports.expiring_documents()])

        say("Витрати й дохід по авто, грн:")
        print_table(["Авто", "Пальне", "ТО", "Інциденти", "Разом", "Дохід", "Грн/км"],
                    [(c.plate_number, c.fuel_cost, c.maintenance_cost, c.incident_cost, c.total_cost,
                      c.revenue, c.cost_per_km)
                     for c in uow.reports.vehicle_costs()])

        say("Витрата пального за 90 днів, л/100 км:")
        print_table(["Авто", "Модель", "Факт", "Норма", "Відхилення, %"],
                    [(f.plate_number, f.model, f.actual_per_100km, f.norm_per_100km, f.deviation_pct)
                     for f in uow.reports.fuel_consumption()])

        say("Водії:")
        print_table(["Водій", "Рейсів", "Км", "Дохід", "Вчасно, %", "Інцидентів", "З вини"],
                    [(d.driver_name, d.trips_completed, d.km_driven, d.revenue, d.on_time_pct,
                      d.incidents, d.incidents_at_fault)
                     for d in uow.reports.driver_performance()])

        say("Витрати по місяцях і депо, грн:")
        print_table(["Місяць", "Депо", "Пальне", "ТО", "Інциденти", "Разом"],
                    [(m.month.strftime("%Y-%m"), m.depot_code, m.fuel_cost, m.maintenance_cost,
                      m.incident_cost, m.total_cost)
                     for m in uow.reports.monthly_costs()])
        uow.commit()


SCENARIOS = [
    ("Нове авто, новий водій, закріплення і рейс в одній транзакції", register_vehicle),
    ("Відкат: архівація авто із запланованим рейсом, savepoint", rollback),
    ("Рейс і заправка оновлюють пробіг; ТО знімає авто з лінії", trip_and_maintenance),
    ("Архівація (soft delete), відновлення та журнал змін", soft_delete),
    ("Звіти з розрізів даних", reports),
]


def main() -> None:
    # SQL_LOG_LEVEL=DEBUG показує кожен SQL-запит застосунку
    logging.basicConfig(level=os.getenv("SQL_LOG_LEVEL", "WARNING").upper(), stream=sys.stdout,
                        format="%(asctime)s %(levelname)-5s %(name)s - %(message)s")
    ctx = DemoContext()
    try:
        for number, (text, scenario) in enumerate(SCENARIOS, start=1):
            title(number, text)
            scenario(ctx)
    except DbError as e:
        print("Демо зупинено:", e.diag.message_primary or e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
