from __future__ import annotations

import json
import logging
from ipaddress import ip_address
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


logger = logging.getLogger("uvicorn.error")


def enrich_router_ip(database, router_id: int, public_ip: str, endpoint: str) -> None:
    """Resolve coarse IP ownership data and cache it on the matching router row."""
    try:
        address = ip_address(public_ip)
        if not address.is_global or not endpoint:
            return
        url = endpoint.format(ip=address.compressed)
        request = Request(url, headers={"User-Agent": "router-support/1.0"})
        with urlopen(request, timeout=4) as response:  # noqa: S310 - configured endpoint
            payload = response.read(65537)
        if len(payload) > 65536:
            raise ValueError("IP lookup response is too large")
        result = json.loads(payload)
        if not isinstance(result, dict):
            raise ValueError("IP lookup response is not an object")
        if result.get("success") is False:
            raise ValueError(result.get("message") or "IP lookup was rejected")
        connection = result.get("connection") or {}
        values = {
            "ip_country": str(result.get("country") or "")[:128],
            "ip_region": str(result.get("region") or "")[:128],
            "ip_city": str(result.get("city") or "")[:128],
            "ip_isp": str(connection.get("isp") or connection.get("org") or "")[:256],
            "ip_asn": str(
                connection.get("asn")
                or connection.get("asn_number")
                or connection.get("number")
                or ""
            )[:64],
        }
        with database.connect() as db:
            db.execute(
                """UPDATE routers
                   SET ip_country = ?, ip_region = ?, ip_city = ?, ip_isp = ?, ip_asn = ?
                   WHERE id = ? AND public_ip = ?""",
                (*values.values(), router_id, public_ip),
            )
        logger.info(
            "router IP information updated router_id=%s public_ip=%s country=%s isp=%s",
            router_id,
            public_ip,
            values["ip_country"],
            values["ip_isp"],
        )
    except (HTTPError, URLError, OSError, ValueError, TypeError, KeyError) as error:
        logger.warning(
            "router IP information lookup failed router_id=%s public_ip=%s error=%s",
            router_id,
            public_ip,
            error,
        )
