from dataclasses import replace
from datetime import UTC, datetime, timedelta
from ipaddress import IPv4Network
from pathlib import Path

from fastapi.testclient import TestClient

from backend.access import LoginAttemptLimiter
from backend.config import Settings
from backend.main import create_app


UUID = "123e4567-e89b-12d3-a456-426614174000"
SECOND_UUID = "223e4567-e89b-12d3-a456-426614174001"
PUBLIC_KEY = "ssh-ed25519 " + "A" * 48


def settings(tmp_path: Path) -> Settings:
    return Settings(
        database_path=tmp_path / "test.db",
        bootstrap_token="bootstrap-test-token",
        engineer_token="engineer-test-token",
        device_token_pepper="test-pepper-not-for-production",
        ssh_host="support.example.com",
        ssh_host_key="ssh-ed25519 AAAATESTHOSTKEY",
        ssh_user="router-tunnel",
        ssh_port=2222,
        reverse_port_start=22001,
        reverse_port_end=22003,
        authorized_keys_file=tmp_path / "authorized_keys",
        support_private_key=tmp_path / "support_key",
        support_public_key=tmp_path / "support_key.pub",
        public_base_domain="support.example.test",
        support_session_seconds=3600,
        heartbeat_timeout_seconds=90,
        panel_allowed_networks=(IPv4Network("0.0.0.0/0"),),
        ip_lookup_url="",
    )


def test_registration_heartbeat_and_listing(tmp_path: Path):
    (tmp_path / "support_key.pub").write_text("ssh-ed25519 " + "C" * 48)
    with TestClient(
        create_app(settings(tmp_path)), client=("127.0.0.1", 50000)
    ) as client:
        registration = client.post(
            "/api/routers/register",
            headers={"Authorization": "Bearer bootstrap-test-token"},
            json={
                "uuid": UUID,
                "hostname": "router-1",
                "model": "Archer C6",
                "firmware": "23.05.5",
                "ram_mb": 64,
                "mac_address": "aa:bb:cc:dd:ee:ff",
                "public_key": PUBLIC_KEY,
            },
        )
        assert registration.status_code == 201
        result = registration.json()
        assert result["reverse_port"] == 22001
        assert result["ssh_server_port"] == 2222
        assert result["device_token"]
        assert result["ssh_host_key"].startswith("ssh-ed25519 ")
        assert client.get("/api/logs").status_code == 403
        log_response = client.get(
            "/api/logs", headers={"Authorization": "Bearer engineer-test-token"}
        )
        assert log_response.status_code == 200
        assert log_response.json()[-1]["category"] == "registration"
        assert log_response.json()[-1]["router_uuid"] == UUID

        duplicate = client.post(
            "/api/routers/register",
            headers={"Authorization": "Bearer bootstrap-test-token"},
            json={
                "uuid": UUID,
                "hostname": "router-1",
                "public_key": PUBLIC_KEY,
            },
        )
        assert duplicate.status_code == 201
        assert duplicate.json()["reverse_port"] == 22001
        assert duplicate.json()["device_token"] != result["device_token"]
        result = duplicate.json()

        key_takeover = client.post(
            "/api/routers/register",
            headers={"Authorization": "Bearer bootstrap-test-token"},
            json={
                "uuid": UUID,
                "hostname": "attacker",
                "public_key": "ssh-ed25519 " + "B" * 48,
            },
        )
        assert key_takeover.status_code == 409

        heartbeat = client.post(
            "/api/routers/heartbeat",
            headers={"Authorization": f"Bearer {result['device_token']}"},
            json={
                "uuid": UUID,
                "firmware": "24.10.0",
                "mac_address": "AA:BB:CC:DD:EE:01",
                "ssh_host_key": "ssh-ed25519 " + "D" * 48,
            },
        )
        assert heartbeat.status_code == 200
        assert heartbeat.json()["support_public_key"].startswith("ssh-ed25519 ")
        assert heartbeat.json()["ssh_host"] == "support.example.com"
        assert heartbeat.json()["ssh_server_port"] == 2222
        assert heartbeat.json()["tunnel_connected"] is False

        assert client.get("/api/routers").status_code == 403
        assert client.get(
            "/api/routers", headers={"Authorization": "Bearer wrong"}
        ).status_code == 403
        listing = client.get(
            "/api/routers",
            headers={"Authorization": "Bearer engineer-test-token"},
        )
        assert listing.status_code == 200
        assert listing.json()[0]["firmware"] == "24.10.0"
        assert listing.json()[0]["mac_address"] == "AA:BB:CC:DD:EE:01"
        assert listing.json()[0]["public_ip"] == "127.0.0.1"
        assert listing.json()[0]["notes"] == ""
        assert listing.json()[0]["status"] == "degraded"
        assert listing.json()[0]["tunnel_status"] == "disconnected"

        missing_tunnel = client.post(
            f"/api/routers/{UUID}/support/start",
            headers={"Authorization": "Bearer engineer-test-token"},
        )
        assert missing_tunnel.status_code == 409
        assert "reverse SSH tunnel is not listening" in missing_tunnel.json()["detail"]

    keys = (tmp_path / "authorized_keys").read_text()
    assert 'permitlisten="127.0.0.1:22001"' in keys
    assert PUBLIC_KEY in keys


def test_notes_and_delete_router_connection(tmp_path: Path):
    (tmp_path / "support_key.pub").write_text("ssh-ed25519 " + "C" * 48)
    app = create_app(settings(tmp_path))
    headers = {"Authorization": "Bearer engineer-test-token"}
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        registration = client.post(
            "/api/routers/register",
            headers={"Authorization": "Bearer bootstrap-test-token"},
            json={
                "uuid": UUID,
                "hostname": "router-1",
                "public_key": PUBLIC_KEY,
            },
        )
        assert registration.status_code == 201

        notes = client.put(
            f"/api/routers/{UUID}/notes",
            headers=headers,
            json={"notes": "Склад №2, контакт Иван"},
        )
        assert notes.status_code == 200
        assert notes.json() == {"notes": "Склад №2, контакт Иван"}
        assert client.get("/api/routers", headers=headers).json()[0]["notes"] == (
            "Склад №2, контакт Иван"
        )

        deleted = client.delete(f"/api/routers/{UUID}", headers=headers)
        assert deleted.status_code == 204
        assert client.get("/api/routers", headers=headers).json() == []
        assert (tmp_path / "authorized_keys").read_text() == ""
        assert client.delete(f"/api/routers/{UUID}", headers=headers).status_code == 404


def test_reenrollment_by_mac_preserves_router_and_reverse_port(tmp_path: Path):
    (tmp_path / "support_key.pub").write_text("ssh-ed25519 " + "C" * 48)
    headers = {"Authorization": "Bearer engineer-test-token"}
    with TestClient(
        create_app(settings(tmp_path)), client=("127.0.0.1", 50000)
    ) as client:
        first = client.post(
            "/api/routers/register",
            headers={"Authorization": "Bearer bootstrap-test-token"},
            json={
                "uuid": UUID,
                "hostname": "router-before-reset",
                "mac_address": "AA:BB:CC:DD:EE:FF",
                "public_key": PUBLIC_KEY,
            },
        )
        assert first.status_code == 201
        assert first.json()["reverse_port"] == 22001
        client.put(
            f"/api/routers/{UUID}/notes",
            headers=headers,
            json={"notes": "keep after factory reset"},
        )

        second = client.post(
            "/api/routers/register",
            headers={"Authorization": "Bearer bootstrap-test-token"},
            json={
                "uuid": SECOND_UUID,
                "hostname": "router-after-reset",
                "mac_address": "aa:bb:cc:dd:ee:ff",
                "public_key": "ssh-ed25519 " + "B" * 48,
            },
        )
        assert second.status_code == 201
        assert second.json()["reverse_port"] == 22001

        listing = client.get("/api/routers", headers=headers).json()
        assert len(listing) == 1
        assert listing[0]["uuid"] == SECOND_UUID
        assert listing[0]["notes"] == "keep after factory reset"
        keys = (tmp_path / "authorized_keys").read_text()
        assert f"router-{SECOND_UUID}" in keys
        assert f"router-{UUID}" not in keys


def test_active_session_can_be_stopped_from_another_admin_client(tmp_path: Path):
    (tmp_path / "support_key.pub").write_text("ssh-ed25519 " + "C" * 48)
    app = create_app(settings(tmp_path))
    headers = {"Authorization": "Bearer engineer-test-token"}
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        client.post(
            "/api/routers/register",
            headers={"Authorization": "Bearer bootstrap-test-token"},
            json={"uuid": UUID, "hostname": "router-1", "public_key": PUBLIC_KEY},
        )
        now = datetime.now(UTC).replace(microsecond=0)
        with app.state.database.connect() as connection:
            router_id = connection.execute(
                "SELECT id FROM routers WHERE uuid = ?", (UUID,)
            ).fetchone()["id"]
            cursor = connection.execute(
                """INSERT INTO support_sessions
                   (router_id, started_at, expires_at, status, token_digest,
                    luci_port, v2raya_port, app_port)
                   VALUES (?, ?, ?, 'active', ?, ?, ?, ?)""",
                (
                    router_id,
                    now.isoformat(),
                    (now + timedelta(hours=1)).isoformat(),
                    "digest",
                    31011,
                    31012,
                    31013,
                ),
            )
            session_id = cursor.lastrowid

        active = client.get("/api/sessions/active", headers=headers)
        assert active.status_code == 200
        assert active.json()[0]["id"] == session_id
        assert active.json()[0]["uuid"] == UUID

        stopped = client.post(f"/api/sessions/{session_id}/stop", headers=headers)
        assert stopped.status_code == 200
        assert stopped.json() == {"status": "stopped"}
        assert client.get("/api/sessions/active", headers=headers).json() == []


def test_rejects_invalid_credentials(tmp_path: Path):
    (tmp_path / "support_key.pub").write_text("ssh-ed25519 " + "C" * 48)
    with TestClient(create_app(settings(tmp_path))) as client:
        response = client.post(
            "/api/routers/register",
            headers={"Authorization": "Bearer wrong"},
            json={
                "uuid": UUID,
                "hostname": "router-1",
                "public_key": PUBLIC_KEY,
            },
        )
        assert response.status_code == 401


def test_frontend_requires_login_and_rejects_invalid_token(tmp_path: Path):
    (tmp_path / "support_key.pub").write_text("ssh-ed25519 " + "C" * 48)
    with TestClient(
        create_app(settings(tmp_path)),
        base_url="https://testserver",
        client=("127.0.0.1", 50000),
    ) as client:
        response = client.get("/", follow_redirects=False)
        assert response.status_code == 303
        assert response.headers["location"] == "/login"
        assert response.headers["cache-control"] == "no-store"
        login_page = client.get("/login")
        assert login_page.status_code == 200
        assert login_page.headers["cache-control"] == "no-store"
        assert client.get("/app.js").status_code == 403
        assert client.get("/api/auth/connection-token").status_code == 403

        rejected = client.post(
            "/api/auth/login", headers={"Authorization": "Bearer wrong"}
        )
        assert rejected.status_code == 403

        client.cookies.set("router_support_engineer", "invalid")
        stale_cookie = client.get("/", follow_redirects=False)
        assert stale_cookie.status_code == 303
        assert stale_cookie.headers["location"] == "/login"
        assert "router_support_engineer=\"\"" in stale_cookie.headers["set-cookie"]
        client.cookies.clear()

        login = client.post(
            "/api/auth/login",
            headers={"Authorization": "Bearer engineer-test-token"},
        )
        assert login.status_code == 204
        cookie = login.headers["set-cookie"].lower()
        assert "httponly" in cookie
        assert "secure" in cookie
        assert "samesite=strict" in cookie

        response = client.get("/")
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-store"
        assert "Router Support" in response.text
        assert client.get("/app.js").status_code == 200
        assert client.get("/api/routers").status_code == 200
        connection_token = client.get("/api/auth/connection-token")
        assert connection_token.status_code == 200
        assert connection_token.json() == {
            "token": "bootstrap-test-token",
            "ssh_host": "support.example.com",
            "ssh_port": 2222,
            "install_command": (
                "wget -qO- https://raw.githubusercontent.com/blyaxyz/"
                "router-support/main/bootstrap-openwrt.sh | "
                "sh -s -- -server support.example.test -token bootstrap-test-token"
            ),
        }

        assert client.post("/api/auth/logout").status_code == 204
        assert client.get("/api/routers").status_code == 403


def test_rename_and_terminal_ticket_require_engineer_token(tmp_path: Path, monkeypatch):
    (tmp_path / "support_key.pub").write_text("ssh-ed25519 " + "C" * 48)
    app = create_app(settings(tmp_path))
    renamed = []
    monkeypatch.setattr(
        app.state.session_manager,
        "rename_router",
        lambda router_uuid, hostname: renamed.append((router_uuid, hostname)),
    )
    monkeypatch.setattr(
        app.state.session_manager,
        "terminal_spec",
        lambda router_uuid: (1, ["ssh"]),
    )
    headers = {"Authorization": "Bearer engineer-test-token"}
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        assert client.patch(f"/api/routers/{UUID}", json={"hostname": "edge-01"}).status_code == 403
        renamed_response = client.patch(
            f"/api/routers/{UUID}", headers=headers, json={"hostname": "edge-01"}
        )
        assert renamed_response.status_code == 200
        assert renamed == [(UUID, "edge-01")]
        assert client.patch(
            f"/api/routers/{UUID}", headers=headers, json={"hostname": "bad name"}
        ).status_code == 422
        ticket = client.post(
            f"/api/routers/{UUID}/terminal/ticket", headers=headers
        )
        assert ticket.status_code == 200
        assert ticket.json()["ticket"]


def test_login_blocks_ip_after_five_failures(tmp_path: Path):
    (tmp_path / "support_key.pub").write_text("ssh-ed25519 " + "C" * 48)
    with TestClient(
        create_app(settings(tmp_path)),
        base_url="https://testserver",
        client=("127.0.0.1", 50000),
    ) as client:
        headers = {
            "Authorization": "Bearer wrong",
            "X-Forwarded-For": "203.0.113.20",
        }
        for _ in range(4):
            assert client.post("/api/auth/login", headers=headers).status_code == 403
        blocked = client.post("/api/auth/login", headers=headers)
        assert blocked.status_code == 429
        assert 1 <= int(blocked.headers["retry-after"]) <= 300

        correct = client.post(
            "/api/auth/login",
            headers={
                "Authorization": "Bearer engineer-test-token",
                "X-Forwarded-For": "203.0.113.20",
            },
        )
        assert correct.status_code == 429

        another_ip = client.post(
            "/api/auth/login",
            headers={
                "Authorization": "Bearer engineer-test-token",
                "X-Forwarded-For": "203.0.113.21",
            },
        )
        assert another_ip.status_code == 204


def test_login_block_expires_after_five_minutes():
    limiter = LoginAttemptLimiter()
    for attempt in range(4):
        assert limiter.record_failure("203.0.113.20", now=float(attempt)) == 0
    assert limiter.record_failure("203.0.113.20", now=4.0) == 300
    assert limiter.retry_after("203.0.113.20", now=4.0) == 300
    assert limiter.retry_after("203.0.113.20", now=304.0) == 0


def test_panel_access_is_limited_by_forwarded_client_ip(tmp_path: Path):
    (tmp_path / "support_key.pub").write_text("ssh-ed25519 " + "C" * 48)
    restricted = replace(
        settings(tmp_path),
        panel_allowed_networks=(
            IPv4Network("10.0.0.0/8"),
            IPv4Network("172.16.0.0/12"),
            IPv4Network("192.168.0.0/16"),
        ),
    )
    with TestClient(
        create_app(restricted),
        base_url="https://testserver",
        client=("127.0.0.1", 50000),
    ) as client:
        assert client.get(
            "/login", headers={"X-Forwarded-For": "192.168.1.44"}
        ).status_code == 200
        assert client.get(
            "/login", headers={"X-Forwarded-For": "10.23.45.67"}
        ).status_code == 200
        assert client.get(
            "/login", headers={"X-Forwarded-For": "172.31.255.254"}
        ).status_code == 200
        assert client.get(
            "/login", headers={"X-Forwarded-For": "203.0.113.20"}
        ).status_code == 403
        assert client.get(
            "/login",
            headers={"X-Forwarded-For": "192.168.1.44, 203.0.113.20"},
        ).status_code == 403

        # Router connectivity and monitoring remain public.
        assert client.get(
            "/healthz", headers={"X-Forwarded-For": "203.0.113.20"}
        ).status_code == 200
        registration = client.post(
            "/api/routers/register",
            headers={
                "Authorization": "Bearer wrong",
                "X-Forwarded-For": "203.0.113.20",
            },
            json={"uuid": UUID, "hostname": "router-1", "public_key": PUBLIC_KEY},
        )
        assert registration.status_code == 401

