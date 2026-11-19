#!/usr/bin/env bash
set -euo pipefail
umask 022

usage() {
    cat <<'EOF'
Usage: install-server.sh --domain support.example.com --ssh-host 203.0.113.10 [options]
       install-server.sh                  # interactive setup

Options:
  --domain DOMAIN     Public panel domain (required)
  --ssh-host HOST     Public IP/name used by OpenWrt SSH tunnels (required)
  --ssh-port PORT     Public SSH port of the VPS (detected, otherwise 22)
  --panel-network MODE  Panel clients: localhost, local/private or public/all
  --telemt-integration Route panel TLS through Telemt SNI fallback on port 443
  --telemt-config FILE Telemt TOML file (default: auto-detect)
  --internal-https-port PORT  Apache TLS upstream for Telemt (default: 8443)
  --allow-wsl         Confirm Windows firewall/port forwarding is configured
  --skip-public-http-check  Bypass WSL public HTTP preflight (not recommended)
  --email EMAIL       Let's Encrypt email; registration without email if omitted
  --ip-certificate IP Request a 6-day Let's Encrypt certificate for this IPv4
  --no-tls            Configure HTTP only (development only)
EOF
    exit 2
}

ask() {
    prompt="$1"
    default_value="${2:-}"
    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt" "$default_value" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    if [ -r /dev/tty ]; then
        IFS= read -r answer </dev/tty
    else
        IFS= read -r answer
    fi
    printf '%s' "${answer:-$default_value}"
}

ask_yes_no() {
    prompt="$1"
    default_value="$2"
    while :; do
        answer="$(ask "$prompt (yes/no)" "$default_value")"
        case "$answer" in
            y|Y|yes|YES|Yes) printf 'yes'; return 0 ;;
            n|N|no|NO|No) printf 'no'; return 0 ;;
            *) echo "Please answer yes or no" >&2 ;;
        esac
    done
}

valid_ipv4() {
    local ipv4="$1" octet
    local -a octets
    [[ "$ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$ipv4"
    for octet in "${octets[@]}"; do
        [ "$octet" -le 255 ] || return 1
    done
}

valid_public_ipv4() {
    local ipv4="$1" first second
    valid_ipv4 "$ipv4" || return 1
    IFS=. read -r first second _ <<<"$ipv4"
    [ "$first" -ne 0 ] && [ "$first" -ne 10 ] && [ "$first" -ne 127 ] && \
        [ "$first" -lt 224 ] || return 1
    [ "$first" -eq 169 ] && [ "$second" -eq 254 ] && return 1
    [ "$first" -eq 172 ] && [ "$second" -ge 16 ] && [ "$second" -le 31 ] && return 1
    [ "$first" -eq 192 ] && [ "$second" -eq 168 ] && return 1
    return 0
}

detect_public_ipv4() {
    local candidate="${ROUTER_SUPPORT_PUBLIC_IP:-}" endpoint
    if valid_public_ipv4 "$candidate"; then
        printf '%s' "$candidate"
        return
    fi
    if command -v curl >/dev/null 2>&1; then
        for endpoint in https://api.ipify.org https://checkip.amazonaws.com; do
            candidate="$(curl -4fsS --max-time 4 "$endpoint" 2>/dev/null || true)"
            candidate="${candidate//$'\n'/}"
            if valid_public_ipv4 "$candidate"; then
                printf '%s' "$candidate"
                return
            fi
        done
    fi
    if [[ "${SSH_CONNECTION:-}" =~ [[:space:]]([0-9]{1,3}(\.[0-9]{1,3}){3})[[:space:]][0-9]{1,5}$ ]]; then
        candidate="${BASH_REMATCH[1]}"
        valid_public_ipv4 "$candidate" && printf '%s' "$candidate"
    fi
    return 0
}

detect_ssh_port() {
    local candidate=""
    if [[ "${SSH_CONNECTION:-}" =~ [[:space:]]([0-9]{1,5})$ ]]; then
        candidate="${BASH_REMATCH[1]}"
    elif [[ "${SSH_CLIENT:-}" =~ [[:space:]]([0-9]{1,5})$ ]]; then
        candidate="${BASH_REMATCH[1]}"
    fi
    if [ -n "$candidate" ] && [ "$candidate" -ge 1 ] && [ "$candidate" -le 65535 ]; then
        printf '%s' "$candidate"
    else
        printf '22'
    fi
}

is_wsl() {
    grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null || \
        grep -qi microsoft /proc/version 2>/dev/null
}

require_wsl_systemd() {
    local init_name
    init_name="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')"
    if [ "$init_name" != "systemd" ]; then
        cat >&2 <<'EOF'
WSL detected, but systemd is not PID 1.
Add this to /etc/wsl.conf:

[boot]
systemd=true

Then run `wsl.exe --shutdown` from Windows PowerShell and start WSL again.
EOF
        exit 1
    fi
}

detect_wsl_ipv4() {
    ip -4 route get 1.1.1.1 2>/dev/null | \
        awk '{for (index = 1; index <= NF; index++) if ($index == "src") {print $(index + 1); exit}}'
}

detect_wsl_networking_mode() {
    local mode="unknown"
    if command -v wslinfo >/dev/null 2>&1; then
        mode="$(wslinfo --networking-mode 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    case "$mode" in nat|mirrored) printf '%s' "$mode" ;; *) printf 'unknown' ;; esac
}

ensure_apache_port_available() {
    local port="$1" listeners
    command -v ss >/dev/null 2>&1 || return 0
    listeners="$(ss -H -ltnp "sport = :$port" 2>/dev/null || true)"
    if [ -n "$listeners" ] && ! grep -q 'apache2' <<<"$listeners"; then
        echo "TCP port $port is already occupied by another service:" >&2
        echo "$listeners" >&2
        echo "Stop or reconfigure that service before installing Router Support." >&2
        exit 1
    fi
}

port_listeners() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 0
    ss -H -ltnp "sport = :$port" 2>/dev/null || true
}

detect_telemt_config() {
    local candidate
    for candidate in /etc/telemt/telemt.toml /etc/telemt/config.toml; do
        [ -f "$candidate" ] && { printf '%s' "$candidate"; return; }
    done
    return 0
}

verify_local_acme_webroot() {
    local probe_name="router-support-preflight-$$" probe_file response
    probe_file="/var/www/router-support-acme/.well-known/acme-challenge/$probe_name"
    printf 'router-support-ok' >"$probe_file"
    chmod 0644 "$probe_file"
    if ! response="$(curl -fsS -H "Host: $DOMAIN" \
        "http://127.0.0.1/.well-known/acme-challenge/$probe_name")"; then
        rm -f "$probe_file"
        echo "Apache cannot serve the local ACME challenge path." >&2
        echo "Check: apache2ctl configtest && journalctl -u apache2 -n 100" >&2
        exit 1
    fi
    rm -f "$probe_file"
    if [ "$response" != "router-support-ok" ]; then
        echo "Unexpected response from the local ACME challenge path." >&2
        exit 1
    fi
}

verify_wsl_public_http() {
    local probe_name probe_file expected response wsl_ip networking_mode
    [ "$WSL_MODE" -eq 1 ] || return 0
    [ "$ENABLE_TLS" -eq 1 ] || return 0
    [ "$SKIP_PUBLIC_HTTP_CHECK" -eq 0 ] || {
        echo "WARNING: WSL public HTTP preflight was explicitly skipped." >&2
        return 0
    }
    probe_name="router-support-wsl-preflight-$$"
    probe_file="/var/www/router-support-acme/.well-known/acme-challenge/$probe_name"
    expected="router-support-wsl-ok-$$"
    printf '%s' "$expected" >"$probe_file"
    echo "Checking public Windows -> WSL HTTP forwarding..." >&2
    response="$(curl -4fsS --noproxy '*' --connect-timeout 6 --max-time 12 \
        "http://$DOMAIN/.well-known/acme-challenge/$probe_name" 2>/dev/null || true)"
    rm -f "$probe_file"
    if [ "$response" = "$expected" ]; then
        echo "Public WSL HTTP preflight passed." >&2
        return 0
    fi
    wsl_ip="$(detect_wsl_ipv4)"
    networking_mode="$(detect_wsl_networking_mode)"
    echo "Public HTTP preflight failed for http://$DOMAIN/." >&2
    echo "Apache works inside WSL, but the public path did not return the ACME challenge." >&2
    echo "WSL networking mode: $networking_mode" >&2
    echo "Current routed WSL address: ${wsl_ip:-unknown}" >&2
    echo >&2
    if [ "$networking_mode" = "mirrored" ]; then
        cat >&2 <<'EOF'
Mirrored mode does not need netsh portproxy. From an elevated Windows PowerShell:
  New-NetFirewallHyperVRule -Name "RouterSupportHTTP" -DisplayName "Router Support HTTP" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 80
  New-NetFirewallHyperVRule -Name "RouterSupportHTTPS" -DisplayName "Router Support HTTPS" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 443

Forward router/cloud TCP 80 and 443 directly to the Windows LAN address.
Remove stale portproxy rules if they reserve ports needed by this installation.
EOF
    else
    cat >&2 <<EOF
From an elevated Windows PowerShell, inspect and recreate portproxy rules:
  netsh interface portproxy show v4tov4
  \$WslIp = (wsl.exe sh -lc "ip -4 route get 1.1.1.1 | sed -n 's/.* src \\([^ ]*\\).*/\\1/p'").Trim()
  netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=80
  netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=80 connectaddress=\$WslIp connectport=80

Also allow TCP 80/443 in Windows firewall and forward router/cloud TCP 80/443 to Windows.
EOF
    fi
    cat >&2 <<'EOF'
The installer will roll back without contacting Let's Encrypt.
Use --skip-public-http-check only when NAT loopback is unavailable and an external test succeeds.
EOF
    exit 1
}

declare -A ROLLBACK_PRESENT=()
ROLLBACK_ACTIVE=0
INSTALL_COMMITTED=0
ROLLBACK_DIR=""
TRACKED_FILES=()

unit_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

unit_is_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

backup_tracked_file() {
    local path="$1" destination
    TRACKED_FILES+=("$path")
    if [ -e "$path" ] || [ -L "$path" ]; then
        ROLLBACK_PRESENT["$path"]=1
        destination="$ROLLBACK_DIR/files$path"
        mkdir -p "$(dirname "$destination")"
        cp -a "$path" "$destination"
    else
        ROLLBACK_PRESENT["$path"]=0
    fi
}

restore_tracked_file() {
    local path="$1" source
    source="$ROLLBACK_DIR/files$path"
    if [ "${ROLLBACK_PRESENT[$path]}" -eq 1 ]; then
        mkdir -p "$(dirname "$path")"
        rm -f "$path"
        cp -a "$source" "$path"
    else
        rm -f "$path"
    fi
}

restore_unit_state() {
    local unit="$1" was_enabled="$2" was_active="$3"
    if [ "$was_enabled" -eq 1 ]; then
        systemctl enable "$unit" >/dev/null 2>&1 || true
    else
        systemctl disable "$unit" >/dev/null 2>&1 || true
    fi
    if [ "$was_active" -eq 1 ]; then
        systemctl start "$unit" >/dev/null 2>&1 || true
    else
        systemctl stop "$unit" >/dev/null 2>&1 || true
    fi
}

capture_initial_state() {
    APACHE_WAS_ACTIVE=0
    ROUTER_SUPPORT_WAS_ACTIVE=0
    CERTBOT_TIMER_WAS_ACTIVE=0
    CERTBOT_TIMER_WAS_ENABLED=0
    SUPPORT_CERTBOT_TIMER_WAS_ACTIVE=0
    SUPPORT_CERTBOT_TIMER_WAS_ENABLED=0
    SSH_WAS_ACTIVE=0
    SSH_WAS_ENABLED=0
    unit_is_active apache2.service && APACHE_WAS_ACTIVE=1
    unit_is_active router-support.service && ROUTER_SUPPORT_WAS_ACTIVE=1
    unit_is_active certbot.timer && CERTBOT_TIMER_WAS_ACTIVE=1
    unit_is_enabled certbot.timer && CERTBOT_TIMER_WAS_ENABLED=1
    unit_is_active router-support-certbot.timer && SUPPORT_CERTBOT_TIMER_WAS_ACTIVE=1
    unit_is_enabled router-support-certbot.timer && SUPPORT_CERTBOT_TIMER_WAS_ENABLED=1
    unit_is_active ssh.service && SSH_WAS_ACTIVE=1
    unit_is_enabled ssh.service && SSH_WAS_ENABLED=1
    return 0
}

begin_install_transaction() {
    local path module
    ROLLBACK_DIR="$(mktemp -d /tmp/router-support-rollback.XXXXXX)"

    if [ -d /etc/apache2 ]; then
        cp -a /etc/apache2 "$ROLLBACK_DIR/apache2"
        APACHE_CONFIG_EXISTED=1
    else
        APACHE_CONFIG_EXISTED=0
    fi

    for path in \
        /etc/apache2/sites-available/router-support.conf \
        /etc/apache2/sites-available/router-support-ip-ssl.conf \
        /etc/apache2/sites-available/router-support-le-ssl.conf \
        /etc/apache2/sites-enabled/router-support.conf \
        /etc/apache2/sites-enabled/router-support-ip-ssl.conf \
        /etc/apache2/sites-enabled/router-support-le-ssl.conf \
        /etc/ssh/sshd_config.d/router-support.conf \
        /etc/tmpfiles.d/router-support-sshd.conf \
        /etc/systemd/system/router-support.service \
        /etc/systemd/system/router-support-certbot.service \
        /etc/systemd/system/router-support-certbot.timer \
        /etc/letsencrypt/renewal-hooks/deploy/router-support-apache \
        /etc/router-support/backend.env; do
        backup_tracked_file "$path"
    done
    for module in proxy proxy_http proxy_wstunnel rewrite ssl; do
        backup_tracked_file "/etc/apache2/mods-enabled/$module.load"
        backup_tracked_file "/etc/apache2/mods-enabled/$module.conf"
    done
    if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
        backup_tracked_file "$TELEMT_CONFIG"
        backup_tracked_file "$TELEMT_CONFIG.router-support-backup"
    fi
    ROLLBACK_ACTIVE=1
}

rollback_install() {
    local path
    set +e
    echo >&2
    echo "Installation did not complete; restoring the previous system state..." >&2
    for path in "${TRACKED_FILES[@]}"; do
        restore_tracked_file "$path"
    done
    if [ "$APACHE_CONFIG_EXISTED" -eq 1 ] && [ -d "$ROLLBACK_DIR/apache2" ]; then
        cp -a "$ROLLBACK_DIR/apache2/." /etc/apache2/
    fi
    systemctl daemon-reload
    restore_unit_state certbot.timer \
        "$CERTBOT_TIMER_WAS_ENABLED" "$CERTBOT_TIMER_WAS_ACTIVE"
    restore_unit_state router-support-certbot.timer \
        "$SUPPORT_CERTBOT_TIMER_WAS_ENABLED" "$SUPPORT_CERTBOT_TIMER_WAS_ACTIVE"
    restore_unit_state ssh.service "$SSH_WAS_ENABLED" "$SSH_WAS_ACTIVE"
    if [ "$ROUTER_SUPPORT_WAS_ACTIVE" -eq 1 ]; then
        systemctl restart router-support.service >/dev/null 2>&1 || true
    else
        systemctl stop router-support.service >/dev/null 2>&1 || true
    fi
    if [ "$SSH_WAS_ACTIVE" -eq 1 ] && sshd -t >/dev/null 2>&1; then
        systemctl reload ssh >/dev/null 2>&1 || true
    fi
    if [ "$APACHE_WAS_ACTIVE" -eq 1 ]; then
        systemctl restart apache2.service >/dev/null 2>&1 || true
    else
        systemctl stop apache2.service >/dev/null 2>&1 || true
    fi
    if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
        systemctl restart telemt.service >/dev/null 2>&1 || true
    fi
    echo "Rollback finished. Previously running services were restored where possible." >&2
}

finish_install() {
    local status="$?"
    trap - EXIT
    trap '' INT TERM
    if [ "$ROLLBACK_ACTIVE" -eq 1 ] && \
        { [ "$INSTALL_COMMITTED" -ne 1 ] || [ "$status" -ne 0 ]; }; then
        rollback_install
    fi
    [ -z "$ROLLBACK_DIR" ] || rm -rf "$ROLLBACK_DIR"
    exit "$status"
}

interrupt_install() {
    echo "Installation interrupted by user" >&2
    exit 130
}

interactive_setup() {
    local public_ip panel_default email_answer listener_80 listener_443 telemt_answer wsl_answer wsl_networking panel_access_choice
    echo "Router Support Panel — server setup" >&2
    if [ "$WSL_MODE" -eq 1 ]; then
        wsl_networking="$(detect_wsl_networking_mode)"
        echo "WSL detected (networking: $wsl_networking)." >&2
        echo "Public installation requires Windows forwarding/firewall for TCP 80, 443 and SSH." >&2
        echo "WSL systemd services do not by themselves keep the WSL VM running." >&2
        wsl_answer="$(ask_yes_no 'Windows networking and automatic WSL startup are configured' no)"
        [ "$wsl_answer" = "yes" ] || {
            echo "Installation cancelled before any changes. See docs/WSL.md." >&2
            exit 0
        }
        ALLOW_WSL=1
    fi
    echo "Ports 80 and 443 must be open in the provider firewall." >&2
    listener_80="$(port_listeners 80)"
    listener_443="$(port_listeners 443)"
    if [ -n "$listener_80" ] && [[ "$listener_80" != *apache2* ]]; then
        echo "TCP port 80 is occupied and is required for ACME HTTP-01:" >&2
        echo "$listener_80" >&2
        echo "The installer has not made any changes." >&2
        exit 1
    fi
    if [[ "$listener_443" == *telemt* ]]; then
        echo "Detected Telemt on TCP port 443:" >&2
        echo "$listener_443" >&2
        telemt_answer="$(ask_yes_no 'Route Router Support HTTPS through Telemt SNI fallback' yes)"
        if [ "$telemt_answer" = "yes" ]; then
            TELEMT_INTEGRATION=1
            TELEMT_CONFIG="$(detect_telemt_config)"
            TELEMT_CONFIG="$(ask 'Telemt configuration file' "${TELEMT_CONFIG:-/etc/telemt/telemt.toml}")"
            INTERNAL_HTTPS_PORT="$(ask 'Internal Apache HTTPS port behind Telemt' '8443')"
        fi
    elif [ -n "$listener_443" ] && [[ "$listener_443" != *apache2* ]]; then
        echo "TCP port 443 is occupied by an unsupported service:" >&2
        echo "$listener_443" >&2
        echo "Automatic coexistence is currently supported for Telemt only." >&2
        echo "The installer has not made any changes." >&2
        exit 1
    fi
    public_ip="$(detect_public_ipv4)"
    panel_default="$public_ip"
    [ -n "$public_ip" ] && echo "Detected public IPv4: $public_ip" >&2
    panel_address="$(ask 'Public panel domain or VPS IPv4 (IP uses sslip.io)' "$panel_default")"
    case "$panel_address" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            SSH_HOST="$panel_address"
            DOMAIN="support.${panel_address//./-}.sslip.io"
            echo "Temporary public domain: $DOMAIN" >&2
            if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
                echo "Telemt routing requires SNI; the sslip.io domain will be used instead of direct IP HTTPS." >&2
            else
                ip_tls_answer="$(ask_yes_no "Include the IPv4 itself in a 6-day Let's Encrypt certificate" yes)"
                [ "$ip_tls_answer" = "yes" ] && IP_CERT_ADDRESS="$panel_address"
            fi
            ;;
        *)
            DOMAIN="$panel_address"
            SSH_HOST="${public_ip:-$DOMAIN}"
            ;;
    esac
    SSH_HOST="$(ask 'Public SSH host/IP of the VPS' "$SSH_HOST")"
    SSH_PORT="$(ask 'Public SSH port of the VPS' "$SSH_PORT")"
    while :; do
        echo >&2
        echo "Panel access by external client IPv4:" >&2
        echo "  1) localhost only (127.0.0.1)" >&2
        echo "  2) all private local networks (10/8, 172.16/12, 192.168/16)" >&2
        echo "  3) all IPv4 addresses (0.0.0.0)" >&2
        panel_access_choice="$(ask 'Panel access mode' '3')"
        case "$panel_access_choice" in
            1) PANEL_ALLOWED_NETWORK="127.0.0.1/32" ;;
            2) PANEL_ALLOWED_NETWORK="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" ;;
            3) PANEL_ALLOWED_NETWORK="0.0.0.0/0" ;;
            *) echo "Choose 1, 2 or 3" >&2; continue ;;
        esac
        if [ "$TELEMT_INTEGRATION" -eq 1 ] && [ "$PANEL_ALLOWED_NETWORK" != "0.0.0.0/0" ]; then
            echo "Telemt SNI forwarding does not preserve the external client IP." >&2
            echo "Choose public access or install without Telemt integration." >&2
            continue
        fi
        break
    done
    email_answer="$(ask "Let's Encrypt email (optional; enter 'skip' to omit)" "skip")"
    if [ "$email_answer" = "skip" ]; then
        EMAIL=""
    else
        EMAIL="$email_answer"
    fi
    tls_answer="$(ask_yes_no "Configure HTTPS with Let's Encrypt" yes)"
    if [ "$tls_answer" != "yes" ]; then
        ENABLE_TLS=0
        IP_CERT_ADDRESS=""
    fi

    echo >&2
    echo "Configuration:" >&2
    echo "  Panel:    $DOMAIN" >&2
    echo "  SSH:      $SSH_HOST:$SSH_PORT" >&2
    echo "  Access:   $PANEL_ALLOWED_NETWORK (external client IPv4)" >&2
    if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
        echo "  HTTPS:    Telemt :443 -> Apache 127.0.0.1:$INTERNAL_HTTPS_PORT" >&2
        echo "  Telemt:   $TELEMT_CONFIG" >&2
    fi
    echo "  TLS:      $([ "$ENABLE_TLS" -eq 1 ] && echo enabled || echo disabled)" >&2
    [ -z "$IP_CERT_ADDRESS" ] || echo "  IP SAN:   $IP_CERT_ADDRESS (short-lived)" >&2
    [ -z "$EMAIL" ] || echo "  Email:    $EMAIL" >&2
    if [ "$WSL_MODE" -eq 1 ]; then
        echo "  Windows:  allow/forward TCP 80, 443 and public SSH $SSH_PORT" >&2
        echo "             do not expose internal 22001-22999, 31000+ or 8443" >&2
        if [ "$PANEL_ALLOWED_NETWORK" != "0.0.0.0/0" ]; then
            echo "  Notice:   restricted client IP modes require WSL mirrored networking" >&2
        fi
    fi
    confirm="$(ask_yes_no 'Start installation' 'yes')"
    [ "$confirm" = "yes" ] || { echo "Installation cancelled" >&2; exit 0; }
}

DOMAIN=""
SSH_HOST=""
SSH_PORT="$(detect_ssh_port)"
EMAIL=""
ENABLE_TLS=1
IP_CERT_ADDRESS=""
TELEMT_INTEGRATION=0
TELEMT_CONFIG=""
INTERNAL_HTTPS_PORT="8443"
PANEL_ALLOWED_NETWORK="0.0.0.0/0"
ALLOW_WSL=0
WSL_MODE=0
SKIP_PUBLIC_HTTP_CHECK=0
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
if is_wsl; then
    WSL_MODE=1
    require_wsl_systemd
fi
if [ "$#" -eq 0 ]; then
    interactive_setup
fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --ssh-host) SSH_HOST="${2:-}"; shift 2 ;;
        --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
        --panel-network) PANEL_ALLOWED_NETWORK="${2:-}"; shift 2 ;;
        --telemt-integration) TELEMT_INTEGRATION=1; shift ;;
        --telemt-config) TELEMT_CONFIG="${2:-}"; shift 2 ;;
        --internal-https-port) INTERNAL_HTTPS_PORT="${2:-}"; shift 2 ;;
        --allow-wsl) ALLOW_WSL=1; shift ;;
        --skip-public-http-check) SKIP_PUBLIC_HTTP_CHECK=1; shift ;;
        --email) EMAIL="${2:-}"; shift 2 ;;
        --ip-certificate) IP_CERT_ADDRESS="${2:-}"; shift 2 ;;
        --no-tls) ENABLE_TLS=0; shift ;;
        *) usage ;;
    esac
done

if [ "$WSL_MODE" -eq 1 ] && [ "$ALLOW_WSL" -ne 1 ]; then
    echo "WSL requires --allow-wsl after Windows port forwarding/firewall is configured" >&2
    exit 2
fi

case "$DOMAIN" in ''|*[!A-Za-z0-9.-]*) usage ;; esac
case "$SSH_HOST" in ''|*[!A-Za-z0-9:.-]*) usage ;; esac
case "$SSH_PORT" in ''|*[!0-9]*) usage ;; esac
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || usage
case "$PANEL_ALLOWED_NETWORK" in
    localhost|127.0.0.1|127.0.0.1/32) PANEL_ALLOWED_NETWORK="127.0.0.1/32" ;;
    local|private|10.0.0.0/8,172.16.0.0/12,192.168.0.0/16)
        PANEL_ALLOWED_NETWORK="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
        ;;
    public|all|0.0.0.0|0.0.0.0/0) PANEL_ALLOWED_NETWORK="0.0.0.0/0" ;;
    *) echo "Invalid --panel-network mode" >&2; exit 2 ;;
esac
case "$INTERNAL_HTTPS_PORT" in ''|*[!0-9]*) usage ;; esac
[ "$INTERNAL_HTTPS_PORT" -ge 1 ] && [ "$INTERNAL_HTTPS_PORT" -le 65535 ] || usage
case "$IP_CERT_ADDRESS" in ''|*[!0-9.]*) [ -z "$IP_CERT_ADDRESS" ] || usage ;; esac
[ "$TELEMT_INTEGRATION" -eq 0 ] || {
    [ -n "$TELEMT_CONFIG" ] || TELEMT_CONFIG="$(detect_telemt_config)"
    case "$TELEMT_CONFIG" in /*) ;; *) echo "Telemt config path must be absolute" >&2; exit 2 ;; esac
    [ -n "$TELEMT_CONFIG" ] && [ -f "$TELEMT_CONFIG" ] || {
        echo "Telemt configuration was not found; use --telemt-config" >&2
        exit 2
    }
}
[ "$ENABLE_TLS" -eq 1 ] || [ -z "$IP_CERT_ADDRESS" ] || {
    echo "--ip-certificate cannot be combined with --no-tls" >&2
    exit 2
}
[ "$TELEMT_INTEGRATION" -eq 0 ] || [ "$ENABLE_TLS" -eq 1 ] || {
    echo "Telemt SNI integration requires HTTPS" >&2
    exit 2
}
[ "$TELEMT_INTEGRATION" -eq 0 ] || [ "$PANEL_ALLOWED_NETWORK" = "0.0.0.0/0" ] || {
    echo "Restricted panel networks require a proxy that preserves client IP; Telemt SNI does not" >&2
    exit 2
}
if [ -n "$IP_CERT_ADDRESS" ] && ! valid_ipv4 "$IP_CERT_ADDRESS"; then
    echo "Invalid public IPv4 address: $IP_CERT_ADDRESS" >&2
    exit 2
fi

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
INSTALL_ROOT="/opt/router-support"
CONFIG_ROOT="/etc/router-support"

ensure_apache_port_available 80
if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
    ensure_apache_port_available "$INTERNAL_HTTPS_PORT"
else
    ensure_apache_port_available 443
fi

export DEBIAN_FRONTEND=noninteractive
capture_initial_state
trap interrupt_install INT TERM
apt-get update
apt-get install -y apache2 ca-certificates certbot curl iproute2 openssh-server \
    python3 python3-venv python3-certbot-apache

ensure_apache_port_available 80
if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
    ensure_apache_port_available "$INTERNAL_HTTPS_PORT"
else
    ensure_apache_port_available 443
fi

trap finish_install EXIT
begin_install_transaction
trap interrupt_install INT TERM

if ! id router-tunnel >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /var/lib/router-tunnel \
        --shell /usr/sbin/nologin router-tunnel
fi

install -d -o root -g root -m 0755 "$INSTALL_ROOT" "$CONFIG_ROOT"
install -d -o router-tunnel -g router-tunnel -m 0700 "$INSTALL_ROOT/data"
install -d -o www-data -g www-data -m 0755 \
    /var/www/router-support-acme/.well-known/acme-challenge
if [ "$PROJECT_ROOT" != "$INSTALL_ROOT" ]; then
    for item in backend frontend openwrt-agent deploy scripts docs \
        requirements.txt requirements-dev.txt pyproject.toml README.md .env.example \
        bootstrap-server.sh bootstrap-openwrt.sh; do
        cp -a "$PROJECT_ROOT/$item" "$INSTALL_ROOT/"
    done
fi

python3 -m venv "$INSTALL_ROOT/.venv"
"$INSTALL_ROOT/.venv/bin/pip" install -r "$INSTALL_ROOT/requirements.txt"

if [ ! -f "$INSTALL_ROOT/data/support_key" ]; then
    runuser -u router-tunnel -- ssh-keygen -q -t ed25519 -N '' \
        -f "$INSTALL_ROOT/data/support_key"
fi
chown router-tunnel:router-tunnel \
    "$INSTALL_ROOT/data/support_key" "$INSTALL_ROOT/data/support_key.pub"
chmod 0600 "$INSTALL_ROOT/data/support_key"
chmod 0644 "$INSTALL_ROOT/data/support_key.pub"

ENV_FILE="$CONFIG_ROOT/backend.env"
if [ ! -f "$ENV_FILE" ]; then
    BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"
    ENGINEER_TOKEN="$(openssl rand -hex 32)"
    TOKEN_PEPPER="$(openssl rand -hex 32)"
    SSH_HOST_KEY="$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
    (
        umask 077
        {
            printf 'ROUTER_SUPPORT_BOOTSTRAP_TOKEN=%s\n' "$BOOTSTRAP_TOKEN"
            printf 'ROUTER_SUPPORT_ENGINEER_TOKEN=%s\n' "$ENGINEER_TOKEN"
            printf 'ROUTER_SUPPORT_TOKEN_PEPPER=%s\n' "$TOKEN_PEPPER"
            printf 'ROUTER_SUPPORT_SSH_HOST=%s\n' "$SSH_HOST"
            printf 'ROUTER_SUPPORT_SSH_HOST_KEY="%s"\n' "$SSH_HOST_KEY"
            printf 'ROUTER_SUPPORT_SSH_USER=router-tunnel\n'
            printf 'ROUTER_SUPPORT_SSH_PORT=%s\n' "$SSH_PORT"
            printf 'ROUTER_SUPPORT_PORT_START=22001\n'
            printf 'ROUTER_SUPPORT_PORT_END=22999\n'
            printf 'ROUTER_SUPPORT_DB=%s/data/router-support.db\n' "$INSTALL_ROOT"
            printf 'ROUTER_SUPPORT_AUTHORIZED_KEYS=%s/data/authorized_keys\n' "$INSTALL_ROOT"
            printf 'ROUTER_SUPPORT_SUPPORT_KEY=%s/data/support_key\n' "$INSTALL_ROOT"
            printf 'ROUTER_SUPPORT_SUPPORT_PUBLIC_KEY=%s/data/support_key.pub\n' "$INSTALL_ROOT"
            printf 'ROUTER_SUPPORT_PUBLIC_DOMAIN=%s\n' "$DOMAIN"
            printf 'ROUTER_SUPPORT_SESSION_SECONDS=3600\n'
            printf 'ROUTER_SUPPORT_HEARTBEAT_TIMEOUT=90\n'
            printf 'ROUTER_SUPPORT_PANEL_ALLOWED_NETWORK=%s\n' "$PANEL_ALLOWED_NETWORK"
            if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
                printf 'ROUTER_SUPPORT_TELEMT_INTEGRATION=1\n'
                printf 'ROUTER_SUPPORT_TELEMT_CONFIG=%s\n' "$TELEMT_CONFIG"
                printf 'ROUTER_SUPPORT_INTERNAL_HTTPS_PORT=%s\n' "$INTERNAL_HTTPS_PORT"
            fi
        } >"$ENV_FILE"
    )
    chmod 0600 "$ENV_FILE"
else
    echo "Keeping existing secrets in $ENV_FILE"
fi

ensure_env_line() {
    key="$1"
    value="$2"
    grep -q "^${key}=" "$ENV_FILE" || printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
}
ensure_env_line ROUTER_SUPPORT_SUPPORT_KEY "$INSTALL_ROOT/data/support_key"
ensure_env_line ROUTER_SUPPORT_SUPPORT_PUBLIC_KEY "$INSTALL_ROOT/data/support_key.pub"
ensure_env_line ROUTER_SUPPORT_PUBLIC_DOMAIN "$DOMAIN"
ensure_env_line ROUTER_SUPPORT_SESSION_SECONDS 3600
ensure_env_line ROUTER_SUPPORT_HEARTBEAT_TIMEOUT 90
ensure_env_line ROUTER_SUPPORT_PANEL_ALLOWED_NETWORK "$PANEL_ALLOWED_NETWORK"
if [ -n "$IP_CERT_ADDRESS" ]; then
    ensure_env_line ROUTER_SUPPORT_TLS_IP "$IP_CERT_ADDRESS"
fi
if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
    ensure_env_line ROUTER_SUPPORT_TELEMT_INTEGRATION 1
    ensure_env_line ROUTER_SUPPORT_TELEMT_CONFIG "$TELEMT_CONFIG"
    ensure_env_line ROUTER_SUPPORT_INTERNAL_HTTPS_PORT "$INTERNAL_HTTPS_PORT"
fi

cp "$INSTALL_ROOT/deploy/systemd/router-support.service" \
    /etc/systemd/system/router-support.service
cp "$INSTALL_ROOT/deploy/sshd/router-support.conf" \
    /etc/ssh/sshd_config.d/router-support.conf
install -d -o root -g root -m 0755 /etc/tmpfiles.d
cp "$INSTALL_ROOT/deploy/systemd/router-support-sshd-tmpfiles.conf" \
    /etc/tmpfiles.d/router-support-sshd.conf
systemd-tmpfiles --create /etc/tmpfiles.d/router-support-sshd.conf
install -d -o root -g root -m 0755 /run/sshd
sed "s/SUPPORT_HOSTNAME/$DOMAIN/g" \
    "$INSTALL_ROOT/deploy/apache/router-support.conf" \
    >/etc/apache2/sites-available/router-support.conf
if [ -n "$IP_CERT_ADDRESS" ]; then
    sed -i "/ServerName $DOMAIN/a\\    ServerAlias $IP_CERT_ADDRESS" \
        /etc/apache2/sites-available/router-support.conf
fi

if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
    [ -f /etc/apache2/ports.conf.router-support-backup ] || \
        cp -a /etc/apache2/ports.conf /etc/apache2/ports.conf.router-support-backup
    sed "s/SUPPORT_INTERNAL_HTTPS_PORT/$INTERNAL_HTTPS_PORT/g" \
        "$INSTALL_ROOT/deploy/apache/ports-telemt.conf" >/etc/apache2/ports.conf
fi

a2enmod proxy proxy_http proxy_wstunnel rewrite ssl
a2ensite router-support.conf
sshd -t
apache2ctl configtest
systemctl daemon-reload
systemctl enable --now router-support.service
systemctl enable --now ssh.service
if ! systemctl restart apache2; then
    systemctl status apache2 --no-pager >&2 || true
    journalctl -u apache2 -n 50 --no-pager >&2 || true
    echo "Apache failed to start. Resolve the error above, then rerun the installer." >&2
    exit 1
fi
systemctl is-active --quiet apache2 || {
    echo "Apache is not active after restart" >&2
    exit 1
}
verify_local_acme_webroot
verify_wsl_public_http

if [ "$ENABLE_TLS" -eq 1 ]; then
    MANUAL_SSL_VHOST=0
    CERT_NAME=""
    if [ -n "$IP_CERT_ADDRESS" ]; then
        IP_CERTBOT_ROOT="/opt/router-support-certbot"
        python3 -m venv "$IP_CERTBOT_ROOT"
        "$IP_CERTBOT_ROOT/bin/pip" install 'certbot>=5.4'
        CERTBOT_ARGS=(
            certonly --non-interactive --agree-tos
            --preferred-profile shortlived
            --webroot --webroot-path /var/www/router-support-acme
            --cert-name router-support-ip
            --ip-address "$IP_CERT_ADDRESS"
            -d "$DOMAIN"
        )
        if [ -n "$EMAIL" ]; then
            CERTBOT_ARGS+=(--email "$EMAIL")
        else
            CERTBOT_ARGS+=(--register-unsafely-without-email)
        fi
        "$IP_CERTBOT_ROOT/bin/certbot" "${CERTBOT_ARGS[@]}"
        CERT_NAME="router-support-ip"
        MANUAL_SSL_VHOST=1
        cp "$INSTALL_ROOT/deploy/systemd/router-support-certbot.service" \
            /etc/systemd/system/router-support-certbot.service
        cp "$INSTALL_ROOT/deploy/systemd/router-support-certbot.timer" \
            /etc/systemd/system/router-support-certbot.timer
        systemctl disable --now certbot.timer 2>/dev/null || true
        systemctl daemon-reload
        systemctl enable --now router-support-certbot.timer
    elif [ "$TELEMT_INTEGRATION" -eq 1 ]; then
        CERTBOT_ARGS=(
            certonly --webroot --webroot-path /var/www/router-support-acme
            --cert-name router-support-domain -d "$DOMAIN"
            --non-interactive --agree-tos
        )
        if [ -n "$EMAIL" ]; then
            CERTBOT_ARGS+=(--email "$EMAIL")
        else
            CERTBOT_ARGS+=(--register-unsafely-without-email)
        fi
        certbot "${CERTBOT_ARGS[@]}"
        CERT_NAME="router-support-domain"
        MANUAL_SSL_VHOST=1
        install -d -o root -g root -m 0755 /etc/letsencrypt/renewal-hooks/deploy
        install -o root -g root -m 0755 \
            "$INSTALL_ROOT/deploy/certbot-reload-apache.sh" \
            /etc/letsencrypt/renewal-hooks/deploy/router-support-apache
        systemctl enable --now certbot.timer
    else
        CERTBOT_ARGS=(--apache -d "$DOMAIN" --non-interactive --agree-tos --redirect)
        if [ -n "$EMAIL" ]; then
            CERTBOT_ARGS+=(--email "$EMAIL")
        else
            CERTBOT_ARGS+=(--register-unsafely-without-email)
        fi
        certbot "${CERTBOT_ARGS[@]}"
    fi

    if [ "$MANUAL_SSL_VHOST" -eq 1 ]; then
        if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
            SSL_BIND="127.0.0.1:$INTERNAL_HTTPS_PORT"
        else
            SSL_BIND="*:443"
        fi
        sed -e "s/SUPPORT_HOSTNAME/$DOMAIN/g" \
            -e "s/SUPPORT_IP/${IP_CERT_ADDRESS:-$DOMAIN}/g" \
            -e "s/SUPPORT_SSL_BIND/$SSL_BIND/g" \
            -e "s/SUPPORT_CERT_NAME/$CERT_NAME/g" \
            "$INSTALL_ROOT/deploy/apache/router-support-ip-ssl.conf" \
            >/etc/apache2/sites-available/router-support-ip-ssl.conf
        a2ensite router-support-ip-ssl.conf
        apache2ctl configtest
        systemctl reload apache2
    fi

    if [ "$TELEMT_INTEGRATION" -eq 1 ]; then
        ROUTER_SUPPORT_TELEMT_CONFIG="$TELEMT_CONFIG" \
        ROUTER_SUPPORT_INTERNAL_HTTPS_PORT="$INTERNAL_HTTPS_PORT" \
            "$INSTALL_ROOT/deploy/configure-telemt-route.sh"
    fi
fi

for _attempt in $(seq 1 15); do
    if curl --fail --silent http://127.0.0.1:8000/healthz >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
curl --fail --silent --show-error http://127.0.0.1:8000/healthz >/dev/null
if [ "$ENABLE_TLS" -eq 1 ]; then
    echo "Router Support installed: https://$DOMAIN"
    if [ -n "$IP_CERT_ADDRESS" ] && [ "$TELEMT_INTEGRATION" -eq 0 ]; then
        echo "Direct IP access: https://$IP_CERT_ADDRESS"
    fi
else
    echo "Router Support installed without TLS: http://$DOMAIN"
fi
ENGINEER_TOKEN_DISPLAY="$(sed -n 's/^ROUTER_SUPPORT_ENGINEER_TOKEN=//p' "$ENV_FILE")"
BOOTSTRAP_TOKEN_DISPLAY="$(sed -n 's/^ROUTER_SUPPORT_BOOTSTRAP_TOKEN=//p' "$ENV_FILE")"
[ -n "$ENGINEER_TOKEN_DISPLAY" ] || {
    echo "Engineer access token is missing from $ENV_FILE" >&2
    exit 1
}
[ -n "$BOOTSTRAP_TOKEN_DISPLAY" ] || {
    echo "Router connection token is missing from $ENV_FILE" >&2
    exit 1
}
echo
echo "======================================================================"
echo "IMPORTANT: SAVE BOTH TOKENS NOW"
echo
echo "ENGINEER ACCESS TOKEN (website login):"
echo "$ENGINEER_TOKEN_DISPLAY"
echo
echo "ROUTER CONNECTION TOKEN (OpenWrt registration):"
echo "$BOOTSTRAP_TOKEN_DISPLAY"
echo "======================================================================"
echo
echo "Without the engineer token you cannot sign in to the website."
echo "Use the router connection token only when enrolling a new OpenWrt device."
echo "Both tokens are also stored locally in: $ENV_FILE"
echo "Only root can read this file."
echo "After enrolling routers run: $INSTALL_ROOT/deploy/sync-service-domains.sh"
INSTALL_COMMITTED=1

