import json
from datetime import UTC, datetime
from pathlib import Path

from backend.database import Database
from backend.ip_lookup import enrich_router_ip


class FakeResponse:
    def __init__(self, payload: dict):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, _limit: int) -> bytes:
        return self.payload


def test_ip_information_is_cached_for_current_address(tmp_path: Path, monkeypatch):
    database = Database(tmp_path / "lookup.db")
    database.initialize()
    now = datetime.now(UTC).isoformat()
    with database.connect() as connection:
        cursor = connection.execute(
            """INSERT INTO routers
               (uuid, name, ssh_port, public_key, token_digest, public_ip,
                created_at, last_seen)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            ("router-1", "router-1", 22001, "ssh-ed25519 test", "digest", "8.8.8.8", now, now),
        )
        router_id = cursor.lastrowid

    monkeypatch.setattr(
        "backend.ip_lookup.urlopen",
        lambda *_args, **_kwargs: FakeResponse(
            {
                "success": True,
                "country": "United States",
                "region": "California",
                "city": "San Jose",
                "connection": {"isp": "Google LLC", "asn": 15169},
            }
        ),
    )
    enrich_router_ip(database, router_id, "8.8.8.8", "https://example.test/{ip}")

    with database.connect() as connection:
        row = connection.execute(
            """SELECT ip_country, ip_region, ip_city, ip_isp, ip_asn
               FROM routers WHERE id = ?""",
            (router_id,),
        ).fetchone()
    assert dict(row) == {
        "ip_country": "United States",
        "ip_region": "California",
        "ip_city": "San Jose",
        "ip_isp": "Google LLC",
        "ip_asn": "15169",
    }
