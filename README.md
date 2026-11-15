# Router Support Panel

Панель удалённой поддержки OpenWrt. Роутеры сами устанавливают исходящее SSH-соединение
с VPS, поэтому входящие порты на стороне клиента открывать не требуется.

Возможности:

- автоматическая регистрация OpenWrt и создание индивидуального SSH-ключа;
- список устройств со статусом, hostname, UUID, моделью, прошивкой, RAM и MAC-адресом;
- временные support-сессии с автоматическим завершением;
- защищённый доступ к LuCI, V2RayA и дополнительному web-приложению;
- интерактивный SSH-терминал в браузере;
- переименование OpenWrt через поле Hostname;
- установка по домену или непосредственно по публичному IPv4;
- автоматические Let’s Encrypt-сертификаты и резервное копирование.

## Быстрый запуск сервера

Нужен чистый VPS с Debian 12/13, публичным IPv4 и открытыми TCP-портами `80`, `443`,
а также публичным SSH-портом (по умолчанию `22`, можно указать другой). Reverse-порты
`22001–22999` наружу открывать не нужно.

Установка через `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-server.sh | sudo bash
```

Или через `wget`:

```sh
wget -qO- https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-server.sh | sudo bash
```

Bootstrap скачает этот репозиторий и запустит интерактивную настройку. Установщик
спросит:

1. домен панели или публичный IPv4 VPS;
2. публичный SSH-адрес и SSH-порт VPS, включая порт после NAT;
3. email для Let’s Encrypt;
4. нужно ли включить HTTPS;
5. подтверждение установки.

Для типового VPS установщик сам определяет публичный IPv4 и текущий SSH-порт. Во всех
вопросах уже есть безопасные значения по умолчанию, поэтому базовую установку можно
пройти, просто нажимая Enter. Перед началом будет показана итоговая конфигурация.

Если указать IPv4, установщик создаст служебный домен через `sslip.io` и предложит
короткоживущий Let’s Encrypt IP-сертификат с автоматическим обновлением.

В конце установки появится блок `ENGINEER ACCESS TOKEN`. Сохраните этот токен — без
него войти в панель невозможно. Серверная копия находится в
`/etc/router-support/backend.env` и доступна только `root`.

Для установки из уже скачанного репозитория:

```sh
sudo ./deploy/install-server.sh
```

## Подключение OpenWrt

На самом роутере выполните одну команду через `wget`:

```sh
wget -qO- https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-openwrt.sh | sh
```

Или через `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-openwrt.sh | sh
```

Bootstrap скачает с GitHub только файлы минимального shell-агента, спросит HTTPS-адрес
панели и скрыто запросит `ROUTER_SUPPORT_BOOTSTRAP_TOKEN`. Git, Python, Node.js и Docker
на роутер не устанавливаются. После регистрации bootstrap-токен удаляется с устройства,
а приватный SSH-ключ никогда не покидает OpenWrt.

Bootstrap-токен можно посмотреть на VPS:

```sh
sudo grep '^ROUTER_SUPPORT_BOOTSTRAP_TOKEN=' /etc/router-support/backend.env
```

Альтернативный запуск с рабочей станции остаётся доступен:

```sh
./scripts/deploy-router-agent.sh root@192.168.1.1 https://support.example.com
```

После добавления роутеров синхронизируйте TLS-имена сервисов на VPS:

```sh
sudo /opt/router-support/deploy/sync-service-domains.sh
```

## Использование

Откройте адрес панели и введите инженерный токен. Карточка устройства позволяет:

- изменить Hostname;
- начать и завершить поддержку;
- открыть LuCI или V2RayA;
- запустить root SSH-терминал в браузере.

Support-сессия по умолчанию действует один час. После завершения сервер закрывает
локальные форварды, терминалы и старые ссылки.

## Три серверных секрета

- `ROUTER_SUPPORT_ENGINEER_TOKEN` — вход инженера в веб-панель;
- `ROUTER_SUPPORT_BOOTSTRAP_TOKEN` — только регистрация новых роутеров;
- `ROUTER_SUPPORT_TOKEN_PEPPER` — серверный HMAC-секрет, его не вводят ни в браузере,
  ни на роутере.

У каждого зарегистрированного роутера дополнительно есть собственный device-token.
В базе хранится только его HMAC-отпечаток.

## Обновление и резервная копия

Из свежей копии репозитория на VPS:

```sh
sudo ./deploy/update-server.sh
sudo ./deploy/backup-server.sh
```

Обновление сохраняет `/etc/router-support/backend.env`, базу, UUID устройств и ключи.

## Удаление агента

С рабочей станции:

```sh
./scripts/remove-router-agent.sh root@192.168.1.1
```

С удалением UUID, device-token и ключа:

```sh
./scripts/remove-router-agent.sh root@192.168.1.1 --purge
```

## Разработка и проверки

Для локальной разработки нужен Python 3.11 или новее:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
make test
make lint
```

Локальный API запускается командой:

```sh
uvicorn --env-file .env backend.main:app --host 127.0.0.1 --port 8000
```

## Документация

- [Быстрый запуск](docs/QUICKSTART.md)
- [Руководство пользователя](docs/USER_GUIDE.md)
- [Полное развёртывание](docs/DEPLOYMENT.md)
- [Настройки](docs/CONFIGURATION.md)
- [Эксплуатация и диагностика](docs/OPERATIONS.md)

Лицензия: [MIT](LICENSE).
