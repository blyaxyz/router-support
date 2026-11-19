# Router Support Panel

Панель удалённой поддержки OpenWrt. Роутеры сами устанавливают исходящий защищённый
SSH-туннель к серверу, поэтому на стороне клиента не нужны публичный IP, проброс портов
или дополнительное тяжёлое ПО.

Основные возможности:

- автоматическая регистрация OpenWrt и отдельный SSH-ключ для каждого устройства;
- статусы online/offline, hostname, UUID, модель, прошивка, RAM и MAC-адрес;
- временные support-сессии с доступом к LuCI, V2RayA и дополнительному web-приложению;
- интерактивный root SSH-терминал в браузере;
- изменение Hostname роутера из панели;
- установка сервера по домену или публичному IPv4;
- Let’s Encrypt, короткоживущие IP-сертификаты и автоматическое обновление;
- установка, обновление и удаление сервера и OpenWrt-агента одной командой.

## 1. Установка сервера

Основной сценарий — чистый VPS с Debian 12/13 и публичным IPv4. Необходимо разрешить
входящие TCP-порты:

- `80` — проверка Let’s Encrypt и перенаправление на HTTPS;
- `443` — веб-панель и сервисные ссылки;
- публичный SSH-порт VPS — `22` или другой выбранный порт.

Диапазоны `22001–22999`, `31000+` и внутренний порт `8443` открывать наружу нельзя:
они слушают только `127.0.0.1` и используются backend внутри сервера.

Запустите установщик через `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-server.sh | sudo bash
```

Или через `wget`:

```sh
wget -qO- https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-server.sh | sudo bash
```

На чистом сервере откроется quiz. Установщик автоматически определит публичный IPv4 и
текущий SSH-порт и предложит готовые значения по умолчанию. Он спросит:

1. домен панели или публичный IPv4;
2. публичный SSH-адрес и порт VPS;
3. сеть внешних IP, которым разрешён доступ к панели;
4. email Let’s Encrypt, который можно пропустить;
5. нужно ли включить HTTPS;
6. подтверждение итоговой конфигурации.

Для панели доступны три режима: только `127.0.0.1`, все частные локальные IPv4-сети
(`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) или все IPv4-адреса (`0.0.0.0`).
Ограничение применяется к реальному адресу клиента перед Apache, а не к внутреннему
`127.0.0.1:8000`. Регистрация и heartbeat роутеров остаются доступными независимо от
режима.

Если указан только IPv4, будет создан служебный домен вида
`support.203-0-113-10.sslip.io`. При поддержке со стороны Let’s Encrypt установщик также
предложит короткоживущий сертификат непосредственно для IP с автоматическим
обновлением.

Если публичный `443` уже занят Telemt, установщик предложит совместный режим: Telemt
останется на `443`, а HTTPS панели будет направлен по SNI на локальный Apache. Исходная
конфигурация резервируется и восстанавливается при ошибке или удалении проекта.

Установка транзакционная: при ошибке, `Ctrl+C` или `SIGTERM` восстанавливаются Apache,
SSH, systemd, Telemt и созданные конфигурационные файлы.

### Токены после установки

В конце установки выводятся два значения:

- `ENGINEER ACCESS TOKEN` — вход в веб-панель;
- `ROUTER CONNECTION TOKEN` — регистрация новых OpenWrt-устройств.

Сохраните оба токена. Серверные копии находятся в файле, доступном только `root`:

```sh
sudo grep -E '^ROUTER_SUPPORT_(ENGINEER|BOOTSTRAP)_TOKEN=' /etc/router-support/backend.env
```

## 2. Подключение OpenWrt

Выполните на роутере одну команду через `wget`:

```sh
wget -qO- https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-openwrt.sh | sh
```

Или через `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-openwrt.sh | sh
```

Укажите HTTPS-адрес панели и вставьте `ROUTER CONNECTION TOKEN`. Скрипт:

1. создаст или повторно использует постоянный UUID устройства;
2. создаст индивидуальный SSH-ключ непосредственно на роутере;
3. зарегистрирует устройство на сервере;
4. удалит общий connection-токен после регистрации;
5. включит сервис и запустит reverse SSH-туннель.

Приватный ключ роутера не покидает OpenWrt. Агент состоит из небольших shell-скриптов;
Git, Python, Node.js и Docker на роутер не устанавливаются.

### Повторный запуск OpenWrt-bootstrap

Если агент уже установлен, та же команда покажет меню:

```text
1) Update
2) Configure a new server connection
3) Remove
4) Cancel
```

- `Update` обновляет файлы агента без нового connection-токена и сохраняет UUID, ключи
  и индивидуальный device-token.
- `Configure a new server connection` переносит роутер на другой сервер. Старое
  подключение заменяется только после успешной регистрации; при ошибке выполняется
  автоматический откат.
- `Remove` удаляет сервис, но сохраняет идентичность устройства для будущей установки.

Для полного удаления UUID, device-token и ключей выполните на OpenWrt:

```sh
/usr/sbin/router-support-uninstall --purge
```

## 3. Первый вход и начало поддержки

Откройте HTTPS-адрес панели и введите `ENGINEER ACCESS TOKEN`. Без действующей
авторизации основной HTML, JavaScript и API панели недоступны.

После пяти неверных токенов с одного IP дальнейшие попытки блокируются на пять минут.

После входа в шапке отображается connection-токен OpenWrt с кнопкой копирования.
Карточка зарегистрированного устройства позволяет:

- изменить Hostname;
- начать или завершить временную support-сессию;
- открыть LuCI, V2RayA или дополнительное web-приложение;
- запустить интерактивный root SSH-терминал.

После добавления новых роутеров синхронизируйте TLS-имена сервисных поддоменов:

```sh
sudo /opt/router-support/deploy/sync-service-domains.sh
```

Support-сессия по умолчанию действует один час. После завершения сервер закрывает
локальные форварды и терминалы, а выданные ссылки перестают работать.

## 4. Повторный запуск серверного bootstrap

Для обновления или удаления сервера снова выполните ту же команду:

```sh
curl -fsSL https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-server.sh | sudo bash
```

При существующей установке появится меню:

```text
1) Update
2) Remove
3) Cancel
```

Обновление сохраняет базу, ключи, токены и системные настройки. Перед удалением нужно
ввести `REMOVE`; скрипт сначала создаст recovery-архив в
`/var/backups/router-support`, затем удалит сервисы и восстановит конфигурацию Telemt,
если использовалась интеграция. Debian-пакеты и архивы сертификатов Let’s Encrypt
сохраняются.

Ручные команды из локальной копии репозитория:

```sh
sudo ./deploy/install-server.sh
sudo ./deploy/update-server.sh
sudo ./deploy/backup-server.sh
sudo ./deploy/uninstall-server.sh
```

## 5. Как устроен доступ

В проекте используются три серверных секрета:

- `ROUTER_SUPPORT_ENGINEER_TOKEN` — вход инженера в панель;
- `ROUTER_SUPPORT_BOOTSTRAP_TOKEN` — только первичная регистрация или перенос роутера;
- `ROUTER_SUPPORT_TOKEN_PEPPER` — внутренний HMAC-секрет сервера, который нигде не
  вводится вручную.

После регистрации каждый роутер получает отдельный device-token. В SQLite хранится
только его HMAC-отпечаток. Общий bootstrap-токен удаляется с роутера.

Схема соединения:

```text
OpenWrt -- исходящий SSH --> VPS
                               ├── панель HTTPS :443
                               ├── reverse SSH 127.0.0.1:22001+
                               └── временные proxy-порты 127.0.0.1:31000+
```

На стороне OpenWrt не требуется открывать входящие порты. Все сервисные ссылки проходят
через HTTPS reverse proxy и ограничены временем активной support-сессии.

## 6. Разработка и проверки

Для локальной разработки нужен Python 3.11 или новее:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
make test
make lint
```

Локальный API:

```sh
uvicorn --env-file .env backend.main:app --host 127.0.0.1 --port 8000
```

## Документация

- [Быстрый запуск](docs/QUICKSTART.md)
- [Полное развёртывание](docs/DEPLOYMENT.md)
- [Руководство пользователя](docs/USER_GUIDE.md)
- [Настройки](docs/CONFIGURATION.md)
- [Эксплуатация и диагностика](docs/OPERATIONS.md)
- [Установка в WSL 2](docs/WSL.md)

## Частный сценарий: WSL 2

WSL 2 поддерживается для тестовых и специальных развёртываний, но обычный Debian VPS
остаётся рекомендуемым production-вариантом. В WSL необходимо отдельно включить
systemd, обеспечить автоматический запуск дистрибутива и настроить Windows networking.

Снаружи Windows должны быть доступны только TCP `80`, `443` и выбранный публичный
SSH-порт. Все следующие команды запускаются в PowerShell от имени администратора.

### Windows 11: mirrored networking

Добавьте в `%UserProfile%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

Примените настройку:

```powershell
wsl.exe --shutdown
```

Откройте сразу все необходимые порты. Замените `44221` на SSH-порт, который слушает
`sshd` внутри WSL и который будет указан в серверном quiz:

```powershell
$SshPort = 44221
$RequiredPorts = @(80, 443, $SshPort)
$WslCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'

Remove-NetFirewallHyperVRule `
    -Name "RouterSupportInbound" `
    -ErrorAction SilentlyContinue

New-NetFirewallHyperVRule `
    -Name "RouterSupportInbound" `
    -DisplayName "Router Support inbound" `
    -Direction Inbound `
    -VMCreatorId $WslCreatorId `
    -Protocol TCP `
    -LocalPorts $RequiredPorts
```

В режиме `mirrored` правила `netsh portproxy` не нужны.

### WSL 2 NAT: Windows portproxy

В NAT-режиме публичный SSH-порт Windows может отличаться от внутреннего порта WSL.
Следующий пример направляет Windows `44221` на WSL `22`, а `80/443` — на одноимённые
порты:

```powershell
$PublicSshPort = 44221
$WslSshPort = 22
$WslIp = (wsl.exe sh -lc "ip -4 route get 1.1.1.1 | sed -n 's/.* src \([^ ]*\).*/\1/p'").Trim()

if (-not $WslIp) {
    throw "Не удалось определить IPv4-адрес WSL"
}

$PortMap = @(
    @{ Public = 80; Internal = 80 },
    @{ Public = 443; Internal = 443 },
    @{ Public = $PublicSshPort; Internal = $WslSshPort }
)

foreach ($Port in $PortMap) {
    netsh interface portproxy delete v4tov4 `
        listenaddress=0.0.0.0 `
        listenport=$($Port.Public) | Out-Null

    netsh interface portproxy add v4tov4 `
        listenaddress=0.0.0.0 `
        listenport=$($Port.Public) `
        connectaddress=$WslIp `
        connectport=$($Port.Internal) | Out-Null
}

Remove-NetFirewallRule `
    -DisplayName "Router Support inbound" `
    -ErrorAction SilentlyContinue

New-NetFirewallRule `
    -DisplayName "Router Support inbound" `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort 80,443,$PublicSshPort

netsh interface portproxy show v4tov4
```

После перезапуска WSL его NAT-адрес может измениться. В таком случае повторно выполните
этот блок, чтобы обновить `connectaddress`.

Если Windows находится за домашним роутером или firewall облачного провайдера, TCP
`80`, `443` и `$PublicSshPort` нужно также направить на Windows-хост.

Не открывайте в Windows порты `22001–22999`, `31000+` и `8443`: они привязаны к
`127.0.0.1` внутри WSL и используются только backend. Дополнительная диагностика и
настройка автоматического запуска описаны в [полной инструкции WSL](docs/WSL.md).

Лицензия: [MIT](LICENSE).
