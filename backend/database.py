from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS routers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT '',
    firmware TEXT NOT NULL DEFAULT '',
    ram_mb INTEGER,
    mac_address TEXT NOT NULL DEFAULT '',
    ssh_port INTEGER NOT NULL UNIQUE,
    public_key TEXT NOT NULL,
    router_ssh_host_key TEXT NOT NULL DEFAULT '',
    token_digest TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT '',
    public_ip TEXT NOT NULL DEFAULT '',
    ip_country TEXT NOT NULL DEFAULT '',
    ip_region TEXT NOT NULL DEFAULT '',
    ip_city TEXT NOT NULL DEFAULT '',
    ip_isp TEXT NOT NULL DEFAULT '',
    ip_asn TEXT NOT NULL DEFAULT '',
    ip_lookup_at TEXT,
    created_at TEXT NOT NULL,
    last_seen TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    router_id INTEGER NOT NULL REFERENCES routers(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    local_port INTEGER NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    UNIQUE(router_id, name)
);

CREATE INDEX IF NOT EXISTS idx_routers_last_seen ON routers(last_seen);

CREATE TABLE IF NOT EXISTS support_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    router_id INTEGER NOT NULL REFERENCES routers(id) ON DELETE CASCADE,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    expires_at TEXT NOT NULL,
    status TEXT NOT NULL,
    token_digest TEXT NOT NULL,
    process_pid INTEGER,
    luci_port INTEGER NOT NULL,
    v2raya_port INTEGER NOT NULL,
    app_port INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_support_sessions_router_status
ON support_sessions(router_id, status);

CREATE TABLE IF NOT EXISTS event_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL,
    level TEXT NOT NULL,
    category TEXT NOT NULL,
    router_uuid TEXT,
    message TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_event_logs_created_at ON event_logs(created_at);
"""


class Database:
    def __init__(self, path: Path):
        self.path = path

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as connection:
            connection.executescript(SCHEMA)
            columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(routers)").fetchall()
            }
            if "router_ssh_host_key" not in columns:
                connection.execute(
                    "ALTER TABLE routers ADD COLUMN router_ssh_host_key TEXT NOT NULL DEFAULT ''"
                )
            if "mac_address" not in columns:
                connection.execute(
                    "ALTER TABLE routers ADD COLUMN mac_address TEXT NOT NULL DEFAULT ''"
                )
            migrations = {
                "notes": "TEXT NOT NULL DEFAULT ''",
                "public_ip": "TEXT NOT NULL DEFAULT ''",
                "ip_country": "TEXT NOT NULL DEFAULT ''",
                "ip_region": "TEXT NOT NULL DEFAULT ''",
                "ip_city": "TEXT NOT NULL DEFAULT ''",
                "ip_isp": "TEXT NOT NULL DEFAULT ''",
                "ip_asn": "TEXT NOT NULL DEFAULT ''",
                "ip_lookup_at": "TEXT",
            }
            for column, definition in migrations.items():
                if column not in columns:
                    connection.execute(
                        f"ALTER TABLE routers ADD COLUMN {column} {definition}"
                    )

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        try:
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

