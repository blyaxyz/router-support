from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID
import re

from pydantic import BaseModel, Field, field_validator

MAC_PATTERN = re.compile(r"^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$")


def normalize_mac(value: str) -> str:
    value = value.strip()
    if not MAC_PATTERN.fullmatch(value):
        raise ValueError("invalid MAC address")
    return value.upper()


class RegisterRequest(BaseModel):
    uuid: UUID
    hostname: str = Field(min_length=1, max_length=128)
    model: str = Field(default="", max_length=256)
    firmware: str = Field(default="", max_length=128)
    ram_mb: int | None = Field(default=None, ge=1, le=65536)
    mac_address: str = ""
    public_key: str = Field(min_length=40, max_length=16384)

    @field_validator("public_key")
    @classmethod
    def validate_public_key(cls, value: str) -> str:
        value = value.strip()
        if "\n" in value or "\r" in value:
            raise ValueError("public key must be one line")
        if not value.startswith(("ssh-ed25519 ", "ssh-rsa ")):
            raise ValueError("only Ed25519 and RSA SSH keys are supported")
        return value

    @field_validator("mac_address")
    @classmethod
    def validate_mac_address(cls, value: str) -> str:
        return normalize_mac(value) if value else ""


class RegisterResponse(BaseModel):
    uuid: UUID
    device_token: str
    ssh_host: str
    ssh_host_key: str
    ssh_user: str
    ssh_server_port: int
    reverse_port: int
    heartbeat_interval: int = 30


class HeartbeatRequest(BaseModel):
    uuid: UUID
    hostname: str | None = Field(default=None, min_length=1, max_length=128)
    model: str | None = Field(default=None, max_length=256)
    firmware: str | None = Field(default=None, max_length=128)
    ram_mb: int | None = Field(default=None, ge=1, le=65536)
    mac_address: str | None = None
    ssh_host_key: str | None = Field(default=None, min_length=40, max_length=16384)

    @field_validator("mac_address")
    @classmethod
    def validate_mac_address(cls, value: str | None) -> str | None:
        return normalize_mac(value) if value else value


class HeartbeatResponse(BaseModel):
    accepted: Literal[True] = True
    server_time: datetime
    support_public_key: str
    ssh_host: str
    ssh_host_key: str
    ssh_server_port: int


class SupportSessionResponse(BaseModel):
    id: int
    status: Literal["active", "stopped", "failed"]
    expires_at: datetime
    luci_url: str
    v2raya_url: str
    app_url: str | None


class RouterResponse(BaseModel):
    uuid: UUID
    name: str
    model: str
    firmware: str
    ram_mb: int | None
    mac_address: str
    ssh_port: int
    status: Literal["online", "degraded", "offline"]
    tunnel_status: Literal["connected", "disconnected"]
    notes: str
    public_ip: str
    ip_country: str
    ip_region: str
    ip_city: str
    ip_isp: str
    ip_asn: str
    created_at: datetime
    last_seen: datetime


class RenameRouterRequest(BaseModel):
    hostname: str = Field(pattern=r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")


class RouterNotesRequest(BaseModel):
    notes: str = Field(default="", max_length=2000)


class TerminalTicketResponse(BaseModel):
    ticket: str
    expires_in: int = 30

