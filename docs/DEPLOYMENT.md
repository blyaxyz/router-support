# Развёртывание

## Требования

### VPS

- Debian 12 или 13;
- минимум 1 vCPU, 1 ГБ RAM и 5 ГБ свободного диска;
- root или sudo;
- публичный IPv4;
- входящие TCP `80`, `443` и публичный SSH-порт (по умолчанию `22`);
- DNS A-записи основного домена и wildcard-поддомена.

Apache, Python venv, Certbot и OpenSSH устанавливаются автоматически. Существующие
нестандартные сервисы не изменяются, но порт `80/443` должен обслуживать Apache.
Перед настройкой установщик проверяет владельцев обоих портов и останавливается с
именем конфликтующего процесса, если `80` или `443` занят не Apache. До запуска
Certbot дополнительно проверяется локальная отдача ACME challenge-файла.

Исключение — обнаруженный Telemt на `443`: квиз предлагает штатную SNI-интеграцию.
Apache слушает TLS только на `127.0.0.1:8443`, а управляемые записи
`[censorship.exclusive_mask]` направляют домен панели и сервисные поддомены через
Telemt. Порт `80` остаётся Apache для HTTP-01 и автоматического продления сертификата.
Перед изменением создаётся `<telemt.toml>.router-support-backup`; при ошибке рестарта
или проверки `/healthz` прежняя конфигурация восстанавливается автоматически.
Маршрутизация использует официальный механизм Telemt
[`censorship.exclusive_mask`](https://github.com/telemt/telemt/blob/main/docs/Config_params/CONFIG_PARAMS.ru.md#exclusive_mask).

В режиме Telemt используется доменное имя, поскольку TLS-подключение непосредственно
к IP не содержит SNI и не может быть отделено от MTProxy-трафика. При вводе IPv4 квиз
автоматически использует `support.<IP>.sslip.io`. После регистрации новых роутеров
`sync-service-domains.sh` обновляет одновременно SAN-сертификат и управляемые маршруты
Telemt.

### Безопасное прерывание установки

После установки системных пакетов скрипт создаёт временный rollback-снимок критических
конфигураций. При `Ctrl+C`, `SIGTERM` или любой ошибке он восстанавливает Apache,
`sshd_config.d`, Router Support systemd units, состояние Certbot timers, `backend.env`
и Telemt TOML. Сервисы, работавшие до запуска, запускаются снова; ранее выключенные
остаются выключенными. На время rollback повторные `Ctrl+C` игнорируются, чтобы не
оборвать восстановление посередине.

APT-пакеты намеренно не удаляются при rollback: автоматическое удаление пакетов после
прерванного `dpkg` опаснее, чем оставить уже скачанные зависимости. До изменения
конфигураций прерывание обрабатывается самим APT; при повторном запуске он продолжит
или завершит настройку пакетов.

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

Quiz спросит домен либо публичный IPv4, публичные SSH-адрес и SSH-порт VPS, email
Let’s Encrypt и подтверждение TLS. При установке через SSH текущий серверный порт
определяется из `SSH_CONNECTION` и предлагается по умолчанию. Порт может отличаться от
`22`, в том числе при NAT-пробросе. Установщик сообщает этот порт агентам, но не меняет
глобальный `Port` в `sshd_config`, чтобы не заблокировать административный доступ к
VPS. Перед изменениями показывается итоговая конфигурация.

Публичный IPv4 определяется через HTTPS-сервис определения адреса, с резервным чтением
адреса из `SSH_CONNECTION`. Поэтому в стандартном сценарии у каждого вопроса есть
готовый вариант: Enter выбирает обнаруженный IPv4, создаваемый домен `sslip.io`,
обнаруженный SSH-порт, пропуск email, включённый TLS и запуск установки. Автоопределение
можно переопределить переменной `ROUTER_SUPPORT_PUBLIC_IP`.

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

Для установки достаточно загрузить один bootstrap-скрипт из репозитория:

```sh
curl -fsSL https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-server.sh | sudo bash
```

Альтернатива через `wget`:

```sh
wget -qO- https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-server.sh | sudo bash
```

После успешного развёртывания установщик выводит инженерный токен доступа крупным
блоком. Его необходимо сохранить: панель запрашивает этот токен при входе. Серверная
копия хранится в `/etc/router-support/backend.env` с правами только для `root`.

Он установит `git`, `curl` и CA-сертификаты, клонирует официальный репозиторий во
временный каталог и запустит серверный quiz. Для форка или другой ветки URL и ref
можно переопределить окружением:

```sh
curl -fsSL https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-server.sh | \
  sudo env \
    ROUTER_SUPPORT_REPO_URL=https://github.com/blyaxyz/router-support.git \
    ROUTER_SUPPORT_REPO_REF=main \
    bash
```

CLI-режим установщика также остаётся доступен:

```sh
./deploy/install-server.sh \
  --domain support.example.com \
  --ssh-host 203.0.113.10 \
  --ssh-port 2222 \
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

Непосредственно на OpenWrt через `wget`:

```sh
wget -qO- https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-openwrt.sh | sh
```

Или через `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-openwrt.sh | sh
```

Bootstrap скачивает только shell-файлы агента и запускает интерактивную установку через
`/dev/tty`, поэтому команды с pipe корректно спрашивают HTTPS-адрес панели и скрытый
bootstrap-token. Если вводится IP вместо домена, TLS-сертификат обязан содержать этот
IP; обычно следует вводить домен панели, а публичный SSH IP агент получит в ответе
сервера.

Установка с рабочей станции также поддерживается:

```sh
./scripts/deploy-router-agent.sh root@192.168.1.1 https://support.example.com
```

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

