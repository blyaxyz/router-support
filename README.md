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

### Все необходимые порты для WSL

Для WSL снаружи нужны только TCP `80`, `443` и публичный SSH-порт, который указан в
серверном quiz. Например, если SSH опубликован на `44221`, откройте сразу весь набор.

Windows 11 с `networkingMode=mirrored`, PowerShell от администратора:

```powershell
$SshPort = 44221
$RequiredPorts = @(80, 443, $SshPort)
Remove-NetFirewallHyperVRule -Name "RouterSupportInbound" -ErrorAction SilentlyContinue
New-NetFirewallHyperVRule -Name "RouterSupportInbound" -DisplayName "Router Support inbound" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts $RequiredPorts
```

Для WSL в NAT-режиме укажите отдельно публичный Windows-порт SSH и фактический порт
`sshd` внутри WSL. В примере Windows `44221` направляется на WSL `22`:

```powershell
$PublicSshPort = 44221
$WslSshPort = 22
$WslIp = (wsl.exe sh -lc "ip -4 route get 1.1.1.1 | sed -n 's/.* src \([^ ]*\).*/\1/p'").Trim()

$PortMap = @(
    @{ Public = 80; Internal = 80 },
    @{ Public = 443; Internal = 443 },
    @{ Public = $PublicSshPort; Internal = $WslSshPort }
)
foreach ($Port in $PortMap) {
    netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$($Port.Public) | Out-Null
    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$($Port.Public) connectaddress=$WslIp connectport=$($Port.Internal) | Out-Null
}
Remove-NetFirewallRule -DisplayName "Router Support inbound" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Router Support inbound" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80,443,$PublicSshPort
netsh interface portproxy show v4tov4
```

Те же три порта должны быть направлены на Windows-хост в домашнем роутере или открыты
в firewall облачного провайдера. Диапазоны reverse SSH `22001–22999`, временные
support-порты `31000+` и внутренний Telemt-порт `8443` слушают только `127.0.0.1` и
доступны backend внутри WSL. Не создавайте для них Windows firewall/portproxy-правила.
Подробности и команды проверки находятся в [инструкции WSL](docs/WSL.md).

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

Если `443` уже занят Telemt, квиз предлагает режим совместной работы. Telemt остаётся
на публичном `443`, а HTTPS панели направляется по SNI на Apache
`127.0.0.1:8443`. Конфигурация Telemt резервируется и автоматически откатывается при
ошибке; Telegram-прокси после настройки проверяется и продолжает работать.

Установка транзакционная на уровне системных конфигураций: при `Ctrl+C`, `SIGTERM` или
ошибке восстанавливаются Apache, SSH, systemd units, таймеры, `backend.env` и Telemt,
после чего сервисы возвращаются в исходное состояние. Уже загруженные Debian-пакеты не
удаляются, чтобы прерывание не повредило пакетный менеджер.

Если указать IPv4, установщик создаст служебный домен через `sslip.io` и предложит
короткоживущий Let’s Encrypt IP-сертификат с автоматическим обновлением.

В конце установки появится блок с двумя значениями: `ENGINEER ACCESS TOKEN` для входа
в панель и `ROUTER CONNECTION TOKEN` для регистрации OpenWrt. Сохраните оба токена.
Серверные копии находятся в `/etc/router-support/backend.env` и доступны только `root`.

Для установки из уже скачанного репозитория:

```sh
sudo ./deploy/install-server.sh
```

Эту же однострочную bootstrap-команду можно запускать повторно. Если сервер уже
установлен, вместо повторного quiz появится меню: обновить проект, удалить его или
отменить операцию. При удалении сначала автоматически создаётся резервная копия базы,
ключей и конфигурации.

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
панели и скрыто запросит показанный установщиком `ROUTER CONNECTION TOKEN`
(`ROUTER_SUPPORT_BOOTSTRAP_TOKEN`). Git, Python, Node.js и Docker
на роутер не устанавливаются. После регистрации bootstrap-токен удаляется с устройства,
а приватный SSH-ключ никогда не покидает OpenWrt.

При повторном запуске OpenWrt-bootstrap определяет установленный агент и предлагает
обновить его без повторной регистрации, настроить подключение к новому серверу, удалить
с сохранением идентичности устройства или отменить действие. На чистом роутере сразу
запускается установка.

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
- [Установка в WSL 2](docs/WSL.md)

Лицензия: [MIT](LICENSE).
