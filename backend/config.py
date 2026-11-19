from __future__ import annotations

import os
from dataclasses import dataclass
from ipaddress import IPv4Network, ip_network
from pathlib import Path


def _required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} must be configured")
    return value


def _panel_networks() -> tuple[IPv4Network, ...]:
    value = os.getenv("ROUTER_SUPPORT_PANEL_ALLOWED_NETWORK", "0.0.0.0/0").strip()
    aliases = {
        "0.0.0.0": "0.0.0.0/0",
        "127.0.0.1": "127.0.0.1/32",
        "local": "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",
        "private": "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",
    }
    networks: list[IPv4Network] = []
    for item in aliases.get(value, value).split(","):
        try:
            network = ip_network(item.strip(), strict=False)
        except ValueError as error:
            raise RuntimeError("invalid ROUTER_SUPPORT_PANEL_ALLOWED_NETWORK") from error
        if not isinstance(network, IPv4Network):
            raise RuntimeError("ROUTER_SUPPORT_PANEL_ALLOWED_NETWORK must be IPv4")
        networks.append(network)
    if not networks:
        raise RuntimeError("ROUTER_SUPPORT_PANEL_ALLOWED_NETWORK is empty")
    return tuple(networks)


@dataclass(frozen=True)
class Settings:
    database_path: Path
    bootstrap_token: str
    engineer_token: str
    device_token_pepper: str
    ssh_host: str
    ssh_host_key: str
    ssh_user: str
    ssh_port: int
    reverse_port_start: int
    reverse_port_end: int
    authorized_keys_file: Path
    support_private_key: Path
    support_public_key: Path
    public_base_domain: str
    support_session_seconds: int
    heartbeat_timeout_seconds: int
    panel_allowed_networks: tuple[IPv4Network, ...]

    @classmethod
    def from_env(cls) -> "Settings":
        start = int(os.getenv("ROUTER_SUPPORT_PORT_START", "22001"))
        end = int(os.getenv("ROUTER_SUPPORT_PORT_END", "22999"))
        if not 1024 <= start <= end <= 65535:
            raise RuntimeError("invalid reverse SSH port range")
        return cls(
            database_path=Path(os.getenv("ROUTER_SUPPORT_DB", "data/router-support.db")),
            bootstrap_token=_required("ROUTER_SUPPORT_BOOTSTRAP_TOKEN"),
            engineer_token=_required("ROUTER_SUPPORT_ENGINEER_TOKEN"),
            device_token_pepper=_required("ROUTER_SUPPORT_TOKEN_PEPPER"),
            ssh_host=os.getenv("ROUTER_SUPPORT_SSH_HOST", "127.0.0.1"),
            ssh_host_key=_required("ROUTER_SUPPORT_SSH_HOST_KEY"),
            ssh_user=os.getenv("ROUTER_SUPPORT_SSH_USER", "router-tunnel"),
            ssh_port=int(os.getenv("ROUTER_SUPPORT_SSH_PORT", "22")),
            reverse_port_start=start,
            reverse_port_end=end,
            authorized_keys_file=Path(
                os.getenv("ROUTER_SUPPORT_AUTHORIZED_KEYS", "data/authorized_keys")
            ),
            support_private_key=Path(
                os.getenv("ROUTER_SUPPORT_SUPPORT_KEY", "data/support_key")
            ),
            support_public_key=Path(
                os.getenv("ROUTER_SUPPORT_SUPPORT_PUBLIC_KEY", "data/support_key.pub")
            ),
            public_base_domain=_required("ROUTER_SUPPORT_PUBLIC_DOMAIN"),
            support_session_seconds=int(
                os.getenv("ROUTER_SUPPORT_SESSION_SECONDS", "3600")
            ),
            heartbeat_timeout_seconds=int(
                os.getenv("ROUTER_SUPPORT_HEARTBEAT_TIMEOUT", "90")
            ),
            panel_allowed_networks=_panel_networks(),
        )

