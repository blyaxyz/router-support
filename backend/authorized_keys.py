from __future__ import annotations

import os
import tempfile
from pathlib import Path


def render_key(public_key: str, reverse_port: int, uuid: str) -> str:
    options = (
        'no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc,'
        f'permitlisten="127.0.0.1:{reverse_port}"'
    )
    key_parts = public_key.split()
    normalized_key = " ".join(key_parts[:2])
    return f"{options} {normalized_key} router-{uuid}\n"


def sync_authorized_keys(path: Path, routers: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    content = "".join(
        render_key(row["public_key"], row["ssh_port"], row["uuid"])
        for row in sorted(routers, key=lambda item: item["ssh_port"])
    )
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

