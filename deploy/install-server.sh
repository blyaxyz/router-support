#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: install-server.sh --domain support.example.com --ssh-host 203.0.113.10 [options]
       install-server.sh                  # interactive setup

Options:
  --domain DOMAIN     Public panel domain (required)
  --ssh-host HOST     Public IP/name used by OpenWrt SSH tunnels (required)
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

interactive_setup() {
    echo "Router Support Panel — server setup" >&2
    echo "Ports 22, 80 and 443 must be open in the provider firewall." >&2
    panel_address="$(ask 'Public panel domain or VPS IPv4 (IP uses sslip.io)' '')"
    case "$panel_address" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            SSH_HOST="$panel_address"
            DOMAIN="support.${panel_address//./-}.sslip.io"
            echo "Temporary public domain: $DOMAIN" >&2
            ip_tls_answer="$(ask_yes_no "Include the IPv4 itself in a 6-day Let's Encrypt certificate" yes)"
            [ "$ip_tls_answer" = "yes" ] && IP_CERT_ADDRESS="$panel_address"
            ;;
        *)
            DOMAIN="$panel_address"
            SSH_HOST="$(ask 'Public SSH host/IP used by routers' "$DOMAIN")"
            ;;
    esac
    EMAIL="$(ask "Let's Encrypt email (optional)" "")"
    tls_answer="$(ask_yes_no "Configure HTTPS with Let's Encrypt" yes)"
    if [ "$tls_answer" != "yes" ]; then
        ENABLE_TLS=0
        IP_CERT_ADDRESS=""
    fi

    echo >&2
    echo "Configuration:" >&2
    echo "  Panel:    $DOMAIN" >&2
    echo "  SSH host: $SSH_HOST" >&2
    echo "  TLS:      $([ "$ENABLE_TLS" -eq 1 ] && echo enabled || echo disabled)" >&2
    [ -z "$IP_CERT_ADDRESS" ] || echo "  IP SAN:   $IP_CERT_ADDRESS (short-lived)" >&2
    [ -z "$EMAIL" ] || echo "  Email:    $EMAIL" >&2
    confirm="$(ask_yes_no 'Start installation' 'yes')"
    [ "$confirm" = "yes" ] || { echo "Installation cancelled" >&2; exit 0; }
}

DOMAIN=""
SSH_HOST=""
EMAIL=""
ENABLE_TLS=1
IP_CERT_ADDRESS=""
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
if [ "$#" -eq 0 ]; then
    interactive_setup
fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --ssh-host) SSH_HOST="${2:-}"; shift 2 ;;
        --email) EMAIL="${2:-}"; shift 2 ;;
        --ip-certificate) IP_CERT_ADDRESS="${2:-}"; shift 2 ;;
        --no-tls) ENABLE_TLS=0; shift ;;
        *) usage ;;
    esac
done

case "$DOMAIN" in ''|*[!A-Za-z0-9.-]*) usage ;; esac
case "$SSH_HOST" in ''|*[!A-Za-z0-9:.-]*) usage ;; esac
case "$IP_CERT_ADDRESS" in ''|*[!0-9.]*) [ -z "$IP_CERT_ADDRESS" ] || usage ;; esac
[ "$ENABLE_TLS" -eq 1 ] || [ -z "$IP_CERT_ADDRESS" ] || {
    echo "--ip-certificate cannot be combined with --no-tls" >&2
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

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apache2 ca-certificates certbot curl openssh-server \
    python3 python3-venv python3-certbot-apache

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
    umask 077
    BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"
    ENGINEER_TOKEN="$(openssl rand -hex 32)"
    TOKEN_PEPPER="$(openssl rand -hex 32)"
    SSH_HOST_KEY="$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
    {
        printf 'ROUTER_SUPPORT_BOOTSTRAP_TOKEN=%s\n' "$BOOTSTRAP_TOKEN"
        printf 'ROUTER_SUPPORT_ENGINEER_TOKEN=%s\n' "$ENGINEER_TOKEN"
        printf 'ROUTER_SUPPORT_TOKEN_PEPPER=%s\n' "$TOKEN_PEPPER"
        printf 'ROUTER_SUPPORT_SSH_HOST=%s\n' "$SSH_HOST"
        printf 'ROUTER_SUPPORT_SSH_HOST_KEY="%s"\n' "$SSH_HOST_KEY"
        printf 'ROUTER_SUPPORT_SSH_USER=router-tunnel\n'
        printf 'ROUTER_SUPPORT_SSH_PORT=22\n'
        printf 'ROUTER_SUPPORT_PORT_START=22001\n'
        printf 'ROUTER_SUPPORT_PORT_END=22999\n'
        printf 'ROUTER_SUPPORT_DB=%s/data/router-support.db\n' "$INSTALL_ROOT"
        printf 'ROUTER_SUPPORT_AUTHORIZED_KEYS=%s/data/authorized_keys\n' "$INSTALL_ROOT"
        printf 'ROUTER_SUPPORT_SUPPORT_KEY=%s/data/support_key\n' "$INSTALL_ROOT"
        printf 'ROUTER_SUPPORT_SUPPORT_PUBLIC_KEY=%s/data/support_key.pub\n' "$INSTALL_ROOT"
        printf 'ROUTER_SUPPORT_PUBLIC_DOMAIN=%s\n' "$DOMAIN"
        printf 'ROUTER_SUPPORT_SESSION_SECONDS=3600\n'
        printf 'ROUTER_SUPPORT_HEARTBEAT_TIMEOUT=90\n'
    } >"$ENV_FILE"
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
if [ -n "$IP_CERT_ADDRESS" ]; then
    ensure_env_line ROUTER_SUPPORT_TLS_IP "$IP_CERT_ADDRESS"
fi

cp "$INSTALL_ROOT/deploy/systemd/router-support.service" \
    /etc/systemd/system/router-support.service
cp "$INSTALL_ROOT/deploy/sshd/router-support.conf" \
    /etc/ssh/sshd_config.d/router-support.conf
sed "s/SUPPORT_HOSTNAME/$DOMAIN/g" \
    "$INSTALL_ROOT/deploy/apache/router-support.conf" \
    >/etc/apache2/sites-available/router-support.conf
if [ -n "$IP_CERT_ADDRESS" ]; then
    sed -i "/ServerName $DOMAIN/a\\    ServerAlias $IP_CERT_ADDRESS" \
        /etc/apache2/sites-available/router-support.conf
fi

a2enmod proxy proxy_http proxy_wstunnel rewrite ssl
a2ensite router-support.conf
sshd -t
apache2ctl configtest
systemctl daemon-reload
systemctl enable --now router-support.service
systemctl reload ssh
systemctl reload apache2

if [ "$ENABLE_TLS" -eq 1 ]; then
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
        sed -e "s/SUPPORT_HOSTNAME/$DOMAIN/g" \
            -e "s/SUPPORT_IP/$IP_CERT_ADDRESS/g" \
            "$INSTALL_ROOT/deploy/apache/router-support-ip-ssl.conf" \
            >/etc/apache2/sites-available/router-support-ip-ssl.conf
        cp "$INSTALL_ROOT/deploy/systemd/router-support-certbot.service" \
            /etc/systemd/system/router-support-certbot.service
        cp "$INSTALL_ROOT/deploy/systemd/router-support-certbot.timer" \
            /etc/systemd/system/router-support-certbot.timer
        systemctl disable --now certbot.timer 2>/dev/null || true
        a2ensite router-support-ip-ssl.conf
        apache2ctl configtest
        systemctl daemon-reload
        systemctl enable --now router-support-certbot.timer
        systemctl reload apache2
    else
        CERTBOT_ARGS=(--apache -d "$DOMAIN" --non-interactive --agree-tos --redirect)
        if [ -n "$EMAIL" ]; then
            CERTBOT_ARGS+=(--email "$EMAIL")
        else
            CERTBOT_ARGS+=(--register-unsafely-without-email)
        fi
        certbot "${CERTBOT_ARGS[@]}"
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
    [ -z "$IP_CERT_ADDRESS" ] || echo "Direct IP access: https://$IP_CERT_ADDRESS"
else
    echo "Router Support installed without TLS: http://$DOMAIN"
fi
ENGINEER_TOKEN_DISPLAY="$(sed -n 's/^ROUTER_SUPPORT_ENGINEER_TOKEN=//p' "$ENV_FILE")"
[ -n "$ENGINEER_TOKEN_DISPLAY" ] || {
    echo "Engineer access token is missing from $ENV_FILE" >&2
    exit 1
}
echo
echo "======================================================================"
echo "IMPORTANT: SAVE THE PANEL ACCESS TOKEN NOW"
echo "Without this token you will not be able to sign in to the website."
echo
echo "ENGINEER ACCESS TOKEN:"
echo "$ENGINEER_TOKEN_DISPLAY"
echo "======================================================================"
echo
echo "The token is also stored locally in: $ENV_FILE"
echo "Only root can read this file."
echo "After enrolling routers run: $INSTALL_ROOT/deploy/sync-service-domains.sh"

