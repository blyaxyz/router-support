# Конфигурация

Основной файл: `/etc/router-support/backend.env`. Права должны быть `0600`, владелец
`root`. После изменения выполните `systemctl restart router-support`.

| Переменная | Назначение | Типовое значение |
|---|---|---|
| `ROUTER_SUPPORT_BOOTSTRAP_TOKEN` | Первичная регистрация устройств | случайная строка |
| `ROUTER_SUPPORT_ENGINEER_TOKEN` | Доступ инженера к панели/API | случайная строка |
| `ROUTER_SUPPORT_TOKEN_PEPPER` | HMAC-защита device/session токенов | случайная строка |
| `ROUTER_SUPPORT_SSH_HOST` | Публичный адрес VPS для роутеров | `203.0.113.10` |
| `ROUTER_SUPPORT_SSH_HOST_KEY` | Публичный host key OpenSSH VPS | `ssh-ed25519 ...` |
| `ROUTER_SUPPORT_SSH_USER` | Ограниченный tunnel-пользователь | `router-tunnel` |
| `ROUTER_SUPPORT_SSH_PORT` | Публичный SSH-порт VPS | `22` |
| `ROUTER_SUPPORT_PORT_START/END` | Пул reverse-портов | `22001/22999` |
| `ROUTER_SUPPORT_DB` | SQLite-файл | `/opt/router-support/data/router-support.db` |
| `ROUTER_SUPPORT_AUTHORIZED_KEYS` | Ключи исходящих туннелей | `/opt/router-support/data/authorized_keys` |
| `ROUTER_SUPPORT_SUPPORT_KEY` | Приватный ключ поддержки | `/opt/router-support/data/support_key` |
| `ROUTER_SUPPORT_SUPPORT_PUBLIC_KEY` | Публичная часть ключа | путь с `.pub` |
| `ROUTER_SUPPORT_PUBLIC_DOMAIN` | Основной HTTPS-домен | `support.example.com` |
| `ROUTER_SUPPORT_TLS_IP` | IPv4 в short-lived сертификате, если включён IP-режим | `203.0.113.10` |
| `ROUTER_SUPPORT_TELEMT_INTEGRATION` | Маршрутизация публичного HTTPS через Telemt | `1` |
| `ROUTER_SUPPORT_TELEMT_CONFIG` | TOML-конфигурация Telemt | `/etc/telemt/telemt.toml` |
| `ROUTER_SUPPORT_INTERNAL_HTTPS_PORT` | Локальный HTTPS-порт Apache за Telemt | `8443` |
| `ROUTER_SUPPORT_SESSION_SECONDS` | Таймаут поддержки | `3600` |
| `ROUTER_SUPPORT_HEARTBEAT_TIMEOUT` | Порог offline | `90` |
| `ROUTER_SUPPORT_PANEL_ALLOWED_NETWORK` | Разрешённая внешняя IPv4-сеть панели | `0.0.0.0/0` |

## Ограничение панели по IP

`ROUTER_SUPPORT_PANEL_ALLOWED_NETWORK` управляет доступом к странице входа, панели,
инженерному API, WebSocket-терминалу и временным support-ссылкам. Регистрация и
heartbeat OpenWrt остаются публичными.

Поддерживаемые режимы установщика:

- `127.0.0.1/32` — панель доступна только с самого сервера;
- `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` — панель доступна с любого частного
  адреса локальной сети;
- `0.0.0.0/0` — панель доступна с любого IPv4-адреса.

В конфигурации можно перечислить несколько IPv4 CIDR через запятую. Значения `local`
и `private` являются сокращениями для всех трёх RFC1918-диапазонов.

Backend доверяет `X-Forwarded-For` только от локального Apache и использует последний
адрес, добавленный reverse proxy. После ручного изменения переменной перезапустите
`router-support.service`. TCP/SNI-проксирование Telemt не сохраняет адрес клиента,
поэтому ограниченные режимы с текущей Telemt-интеграцией недоступны.

После пяти неверных инженерных токенов с одного IP вход блокируется на пять минут.
Успешный вход сбрасывает счётчик, а остальные IP продолжают работать.

## Сервисы роутера

По умолчанию:

| Сервис | Порт | Состояние |
|---|---:|---|
| LuCI | 80 | включён |
| V2RayA | 2017 | включён |
| Web App | 2018 | выключен |

Конфигурация хранится в таблице `services`. Не назначайте V2RayA и Web App один порт.

## UUID и MAC

UUID генерируется агентом один раз из `/proc/sys/kernel/random/uuid` и сохраняется в
`/etc/router-support/uuid`. Обычная переустановка и перезагрузка его не меняют. Новый
UUID создаётся только при отсутствии файла или после удаления с `--purge`.

MAC берётся из `br-lan`; fallback — `lan`, `eth0`, затем первый не-loopback интерфейс.
Сервер проверяет формат, приводит значение к верхнему регистру и обновляет его при
каждом heartbeat.

## Ротация инженерного токена

```sh
NEW_TOKEN="$(openssl rand -hex 32)"
sed -i "s/^ROUTER_SUPPORT_ENGINEER_TOKEN=.*/ROUTER_SUPPORT_ENGINEER_TOKEN=$NEW_TOKEN/" \
  /etc/router-support/backend.env
systemctl restart router-support
```

Сохраните новый токен в менеджере секретов. Старые браузерные сеансы потеряют доступ.

## Смена домена

Измените `ROUTER_SUPPORT_PUBLIC_DOMAIN`, обновите Apache `ServerName/ServerAlias`, DNS и
сертификат. Затем перезапустите backend и Apache. Простая смена только переменной
недостаточна.

