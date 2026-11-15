# Router Support Panel

Централизованная система удалённой поддержки OpenWrt: учёт устройств, исходящие SSH
туннели, LuCI/V2RayA, временные support-сессии, веб-SSH и управление hostname.

## Документация

- [Быстрый запуск](docs/QUICKSTART.md)
- [Руководство пользователя](docs/USER_GUIDE.md)
- [Полное развёртывание](docs/DEPLOYMENT.md)
- [Настройки](docs/CONFIGURATION.md)
- [Эксплуатация и диагностика](docs/OPERATIONS.md)

## Автоматизация

```sh
# Чистый Debian: скачать проект с GitHub и пройти quiz
sudo ./bootstrap-server.sh

# Release-архив
./scripts/package-release.sh

# Сервер Debian 12/13 из распакованного release
sudo ./deploy/install-server.sh

# Агент OpenWrt с рабочей станции
./scripts/deploy-router-agent.sh root@192.168.1.1 https://support.example.com

# Удаление агента с сохранением идентичности
./scripts/remove-router-agent.sh root@192.168.1.1

# Полное удаление UUID, токена и ключа
./scripts/remove-router-agent.sh root@192.168.1.1 --purge
```

## Локальный запуск API

Нужен Python 3.11 или новее.

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Заполните `.env`. Значение `ROUTER_SUPPORT_SSH_HOST_KEY` — публичная часть host key
SSH-сервера, например содержимое `/etc/ssh/ssh_host_ed25519_key.pub` без комментария.
После экспорта переменных запустите:

```sh
uvicorn --env-file .env backend.main:app --host 127.0.0.1 --port 8000
```

Swagger доступен по `/docs`. Маршруты списка устройств защищены
`ROUTER_SUPPORT_ENGINEER_TOKEN`.

## SSH на VPS

Создайте системного пользователя `router-tunnel` без административных прав. Настройте
его `AuthorizedKeysFile` на абсолютный путь из `ROUTER_SUPPORT_AUTHORIZED_KEYS`.
Backend атомарно записывает туда ключи с `permitlisten`, разрешающим каждому роутеру
слушать только назначенный адрес `127.0.0.1:<port>`.

Проверьте, что в `sshd_config` разрешён TCP forwarding, а `GatewayPorts` выключен:

```text
AllowTcpForwarding remote
GatewayPorts no
```

## Установка агента OpenWrt

Скопируйте каталог `openwrt-agent` на роутер и выполните от root:

```sh
cd /tmp/openwrt-agent
./install.sh
```

Без аргументов установщик интерактивно спрашивает HTTPS-адрес панели и bootstrap-token.
Неинтерактивный режим с URL и токеном также поддерживается.

Скрипт:

1. сохраняет UUID между перезагрузками;
2. создаёт индивидуальный Ed25519-ключ (с RSA fallback);
3. регистрирует устройство через HTTPS;
4. закрепляет SSH host key, полученный в защищённом handshake;
5. поддерживает reverse tunnel и heartbeat через `procd`.

После успешной регистрации общий bootstrap-token удаляется с роутера. Индивидуальный
device-token и SSH-ключ остаются в root-only каталоге.

Логи: `logread -e router-support`. Состояние хранится в `/etc/router-support` с
правами только для root.

## Проверки

```sh
pip install -r requirements-dev.txt
pytest
shellcheck openwrt-agent/install.sh openwrt-agent/files/*
```

## Support-сессии

Кнопка в панели создаёт отдельное SSH-подключение только на время поддержки. Ссылки
LuCI/V2RayA используют отдельные TLS-поддомены и HttpOnly cookie; секрет передаётся во
fragment URL и не попадает в HTTP access log. По завершении или таймауту SSH-процесс и
локальные порты уничтожаются.

Hostname можно изменить кнопкой с карандашом на карточке: backend применяет значение
через UCI на OpenWrt и обновляет базу. Кнопка SSH появляется только в активной
support-сессии; браузер получает одноразовый ticket на 30 секунд, а terminal-процесс
закрывается вместе с support-сессией.

До production-развёртывания остаются полноценные пользователи/RBAC, ротация ключей,
детальный аудит команд и wildcard TLS через DNS challenge для большого парка.

