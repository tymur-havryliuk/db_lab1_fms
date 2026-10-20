import os
from typing import Optional

import psycopg2
from psycopg2 import sql
from psycopg2.extensions import connection as PgConnection

from .repositories import (
    AuditRepository, DriverRepository, MaintenanceRepository, ReportRepository, TripRepository,
    VehicleRepository,
)

# Застосунок ходить у базу окремою роллю fleet_app: читає view і викликає процедури
DEFAULT_DSN = os.getenv(
    "FLEET_DSN", "dbname=fleet_db user=fleet_app password=fleet_app host=localhost port=5432")


# Одна транзакція на всі репозиторії: або зберігаються всі зміни, або жодна.
class UnitOfWork:
    vehicles: VehicleRepository
    drivers: DriverRepository
    trips: TripRepository
    maintenance: MaintenanceRepository
    reports: ReportRepository
    audit: AuditRepository

    def __init__(self, user_id: int, dsn: str = DEFAULT_DSN):
        self._dsn = dsn
        self._user_id = user_id
        self._conn: Optional[PgConnection] = None

    def __enter__(self) -> "UnitOfWork":
        self._conn = psycopg2.connect(self._dsn, application_name="fleet-app")
        self._conn.autocommit = False
        try:
            self._bind_user()
        except Exception:
            self._conn.close()
            raise

        self.vehicles = VehicleRepository(self._conn)
        self.drivers = DriverRepository(self._conn)
        self.trips = TripRepository(self._conn)
        self.maintenance = MaintenanceRepository(self._conn)
        self.reports = ReportRepository(self._conn)
        self.audit = AuditRepository(self._conn)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        # усе, що не зафіксовано через commit(), відкочується
        try:
            self._conn.rollback()
        finally:
            self._conn.close()

    def _bind_user(self) -> None:
        # користувач прив'язується до транзакції, тому після кожного commit/rollback - заново
        with self._conn.cursor() as cur:
            cur.execute("CALL fleet.sp_session_begin(%s)", (self._user_id,))

    def commit(self) -> None:
        self._conn.commit()
        self._bind_user()

    def rollback(self) -> None:
        self._conn.rollback()
        self._bind_user()

    def savepoint(self, name: str) -> None:
        with self._conn.cursor() as cur:
            cur.execute(sql.SQL("SAVEPOINT {}").format(sql.Identifier(name)))

    def rollback_to(self, name: str) -> None:
        with self._conn.cursor() as cur:
            cur.execute(sql.SQL("ROLLBACK TO SAVEPOINT {}").format(sql.Identifier(name)))
