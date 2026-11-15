from pathlib import Path

from fastapi.testclient import TestClient

from backend.config import Settings
from backend.main import create_app


UUID = "123e4567-e89b-12d3-a456-426614174000"
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
    )


def test_registration_heartbeat_and_listing(tmp_path: Path):
    (tmp_path / "support_key.pub").write_text("ssh-ed25519 " + "C" * 48)
    with TestClient(create_app(settings(tmp_path))) as client:
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
        assert listing.json()[0]["status"] == "online"

    keys = (tmp_path / "authorized_keys").read_text()
    assert 'permitlisten="127.0.0.1:22001"' in keys
    assert PUBLIC_KEY in keys


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
        create_app(settings(tmp_path)), base_url="https://testserver"
    ) as client:
        response = client.get("/", follow_redirects=False)
        assert response.status_code == 303
        assert response.headers["location"] == "/login"
        assert client.get("/login").status_code == 200
        assert client.get("/app.js").status_code == 403
        assert client.get("/api/auth/connection-token").status_code == 403

        rejected = client.post(
            "/api/auth/login", headers={"Authorization": "Bearer wrong"}
        )
        assert rejected.status_code == 403

        client.cookies.set("router_support_engineer", "invalid")
        assert client.get("/", follow_redirects=False).status_code == 403
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
        assert "Router Support" in response.text
        assert client.get("/app.js").status_code == 200
        assert client.get("/api/routers").status_code == 200
        connection_token = client.get("/api/auth/connection-token")
        assert connection_token.status_code == 200
        assert connection_token.json() == {"token": "bootstrap-test-token"}

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
    with TestClient(app) as client:
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

