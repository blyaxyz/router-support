# Развёртывание

## Требования

### VPS

- Debian 12 или 13;
- минимум 1 vCPU, 1 ГБ RAM и 5 ГБ свободного диска;
- root или sudo;
- публичный IPv4;
- входящие TCP `22`, `80`, `443`;
- DNS A-записи основного домена и wildcard-поддомена.

Apache, Python venv, Certbot и OpenSSH устанавливаются автоматически. Существующие
нестандартные сервисы не изменяются, но порт `80/443` должен обслуживать Apache.

### OpenWrt

- Dropbear `dbclient` и `dropbearkey`;
- `procd`, `jsonfilter`, `curl` либо `uclient-fetch`;
- исходящий HTTPS к панели и SSH к VPS;
- доступно около 30 КБ постоянного места.

Агент не устанавливает Python, Node.js, Docker или базу данных.

## DNS

Пример:

```text
support.example.com    A  203.0.113.10
*.support.example.com  A  203.0.113.10
```

Отдельные имена LuCI/V2RayA имеют вид `luci-r1.support.example.com` и
`v2raya-r1.support.example.com`. Для первых 30 роутеров скрипт выпускает SAN-сертификат.
Для большего парка нужен wildcard-сертификат через DNS challenge.

## Сборка release

На рабочей станции:

```sh
./scripts/package-release.sh
scp router-support-release.tar.gz root@VPS:/tmp/
```

На VPS:

```sh
mkdir -p /tmp/router-support-release
tar -xzf /tmp/router-support-release.tar.gz -C /tmp/router-support-release
cd /tmp/router-support-release
./deploy/install-server.sh
```

Quiz спросит домен либо публичный IPv4, SSH-адрес, email Let’s Encrypt и подтверждение
TLS. Перед изменениями показывается итоговая конфигурация.

### Режим HTTPS непосредственно на IP

Если в quiz указан IPv4, установщик предлагает публично доверенный Let’s Encrypt
IP-сертификат. Он использует профиль `shortlived`, действует 160 часов и проверяется на
renewal каждые 12 часов отдельным systemd timer. Сертификат выпускается через Certbot
5.4+ в режиме `webroot`; после обновления Apache автоматически перечитывает ключи.

У IP нет поддоменов, поэтому сама панель доступна как `https://203.0.113.10`, а LuCI и
V2RayA используют автоматически созданные имена вида
`luci-r1.support.203-0-113-10.sslip.io`. Эти DNS SAN входят в тот же сертификат.

Проверка:

```sh
systemctl status router-support-certbot.timer
/opt/router-support-certbot/bin/certbot certificates
```

Профиль short-lived допускает до 25 имён; текущая схема поддерживает до семи роутеров
на одном IP-сертификате. Для большего парка используйте собственный домен и wildcard
сертификат через DNS challenge.

Официальные материалы: [IP certificates в Certbot](https://letsencrypt.org/2026/03/11/shorter-certs-certbot)
и [профиль shortlived](https://letsencrypt.org/docs/profiles/).

## Установка напрямую из GitHub

После публикации репозитория достаточно загрузить один bootstrap-скрипт:

```sh
curl -fsSL https://raw.githubusercontent.com/ORG/REPO/main/bootstrap-server.sh | sudo bash
```

После успешного развёртывания установщик выводит инженерный токен доступа крупным
блоком. Его необходимо сохранить: панель запрашивает этот токен при входе. Серверная
копия хранится в `/etc/router-support/backend.env` с правами только для `root`.

Он спросит GitHub URL/ветку, установит `git`, `curl` и CA-сертификаты, клонирует проект
во временный каталог и запустит серверный quiz. Для автоматизации URL и ref можно
передать окружением:

```sh
curl -fsSL https://raw.githubusercontent.com/ORG/REPO/main/bootstrap-server.sh | \
  sudo env \
    ROUTER_SUPPORT_REPO_URL=https://github.com/ORG/REPO.git \
    ROUTER_SUPPORT_REPO_REF=main \
    bash
```

CLI-режим установщика также остаётся доступен:

```sh
./deploy/install-server.sh \
  --domain support.example.com \
  --ssh-host 203.0.113.10 \
  --email admin@example.com
```

Неинтерактивный IP-режим:

```sh
./deploy/install-server.sh \
  --domain support.203-0-113-10.sslip.io \
  --ssh-host 203.0.113.10 \
  --ip-certificate 203.0.113.10
```

Скрипт идемпотентен: существующий `/etc/router-support/backend.env` не перезаписывается.

## Что устанавливается

```text
/opt/router-support/                 приложение и venv
/opt/router-support/data/            SQLite, ключи, authorized_keys
/etc/router-support/backend.env      секреты и настройки
/etc/systemd/system/router-support.service
/etc/apache2/sites-available/router-support.conf
/etc/ssh/sshd_config.d/router-support.conf
```

Backend работает как непривилегированный пользователь `router-tunnel` и слушает только
`127.0.0.1:8000`. Apache завершает TLS и проксирует HTTP/WebSocket.

## Добавление роутера

С рабочей станции:

```sh
./scripts/deploy-router-agent.sh root@192.168.1.1 https://support.example.com
```

Либо скопируйте `openwrt-agent` вручную и выполните на роутере:

```sh
./install.sh
```

Интерактивный установщик спросит HTTPS-адрес панели и bootstrap-token. Если вводится
IP вместо домена, TLS-сертификат обязан содержать этот IP; обычно следует вводить домен
панели, а публичный SSH IP агент получит в ответе сервера.

Во время handshake агент создаёт UUID и индивидуальный SSH-ключ, отправляет публичную
часть по HTTPS, а сервер после проверки bootstrap-token назначает reverse-порт и сразу
добавляет ключ в ограниченный `authorized_keys`. Приватный ключ остаётся на OpenWrt.

После регистрации на VPS:

```sh
/opt/router-support/deploy/sync-service-domains.sh
```

## Проверка

```sh
systemctl status router-support
curl https://support.example.com/healthz
ss -lnt | grep 22001
```

На роутере:

```sh
/etc/init.d/router-support status
logread -e router-support
ps w | grep -E '[r]outer-support|[d]bclient'
```

