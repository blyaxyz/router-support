from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path


BEGIN = "# BEGIN ROUTER SUPPORT MANAGED ROUTES"
END = "# END ROUTER SUPPORT MANAGED ROUTES"


def update_config(text: str, port: int, domains: list[str]) -> str:
    parsed = tomllib.loads(text)
    if parsed.get("censorship", {}).get("mask", True) is False:
        raise ValueError("Telemt censorship.mask must be enabled for SNI fallback")
    text = re.sub(
        rf"(?ms)^\s*{re.escape(BEGIN)}\n.*?^\s*{re.escape(END)}\n?",
        "",
        text,
    )
    section_pattern = re.compile(
        r"(?m)^\s*\[censorship\.exclusive_mask\]\s*(?:#.*)?$"
    )
    if re.search(r"(?m)^\s*exclusive_mask\s*=", text):
        raise ValueError(
            "Telemt uses inline censorship.exclusive_mask; convert it to a table first"
        )

    routes = [BEGIN]
    routes.extend(f'"{domain}" = "127.0.0.1:{port}"' for domain in domains)
    routes.append(END)
    block = "\n".join(routes) + "\n"

    match = section_pattern.search(text)
    if match:
        insertion = match.end()
        result = text[:insertion] + "\n" + block + text[insertion:].lstrip("\n")
    else:
        result = text.rstrip() + "\n\n[censorship.exclusive_mask]\n" + block
    tomllib.loads(result)
    return result


def main() -> None:
    path = Path(sys.argv[1])
    port = int(sys.argv[2])
    domains = sys.argv[3:]
    path.write_text(
        update_config(path.read_text(encoding="utf-8"), port, domains),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
