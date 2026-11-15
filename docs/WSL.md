# Установка в WSL 2

WSL поддерживается как отдельный сценарий, но для публичного сервера требует настройки
Windows. По умолчанию WSL 2 работает за NAT, и входящие подключения из интернета не
попадают в Apache внутри Linux автоматически.

Для production надёжнее обычный Debian VPS. Systemd-сервисы сами по себе не удерживают
WSL VM запущенной, поэтому после перезагрузки Windows дистрибутив должен запускаться
задачей Windows либо другим внешним механизмом.

## 1. Включите systemd

Внутри WSL создайте `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Затем в Windows PowerShell выполните:

```powershell
wsl.exe --shutdown
```

После повторного запуска WSL проверьте:

```sh
ps -p 1 -o comm=
systemctl status
```

Первой командой должен быть показан `systemd`.

## 2. Настройте входящие подключения

### Windows 11: mirrored networking

В `%UserProfile%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

После `wsl.exe --shutdown` разрешите все внешние порты проекта одной командой в
PowerShell от администратора. Замените `44221` на публичный SSH-порт из quiz:

```powershell
$SshPort = 44221
$RequiredPorts = @(80, 443, $SshPort)
Remove-NetFirewallHyperVRule -Name "RouterSupportInbound" -ErrorAction SilentlyContinue
New-NetFirewallHyperVRule -Name "RouterSupportInbound" -DisplayName "Router Support inbound" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts $RequiredPorts
```

В mirrored-режиме `netsh portproxy` не нужен. Публичный SSH-порт должен совпадать с
портом, который слушает `sshd` внутри WSL.

### WSL 2 NAT: portproxy

В PowerShell от администратора получите текущий адрес WSL и создайте все необходимые
перенаправления. Публичный SSH-порт Windows может отличаться от порта `sshd` внутри WSL:

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

Адрес WSL в NAT-режиме может измениться после перезапуска. В этом случае правила
`portproxy` необходимо обновлять автоматически при старте Windows.

Проверьте, что `connectaddress` совпадает с текущим адресом:

```powershell
netsh interface portproxy show v4tov4
$WslIp = (wsl.exe sh -lc "ip -4 route get 1.1.1.1 | sed -n 's/.* src \([^ ]*\).*/\1/p'").Trim()
Write-Host $WslIp
Test-NetConnection -ComputerName $WslIp -Port 80
```

Не используйте адреса интерфейсов `docker0` и Docker bridge (`172.17.x.x`,
`172.18.x.x`). Проверить режим и исходящий адрес внутри WSL можно командами:

```sh
wslinfo --networking-mode 2>/dev/null || true
ip -4 route get 1.1.1.1
```

Если TCP-соединение с публичным IP принимается, но HTTP не возвращает ответ, чаще всего
`portproxy` указывает на старый WSL IP. Удалите старое правило и создайте его заново с
актуальным `$WslIp`.

Если Windows находится за роутером или firewall облачного провайдера, `80`, `443` и
публичный SSH-порт нужно дополнительно направить на Windows-хост.

### Какие высокие порты открывать не нужно

- `22001–22999` — reverse SSH-порты зарегистрированных роутеров;
- `31000+` — временные локальные форварды support-сессий;
- `8443` — локальный Apache upstream при совместной работе с Telemt.

Все они создаются на `127.0.0.1` и используются только backend внутри той же WSL.
Публичный браузер всегда обращается к Apache по `443`, а Apache/backend уже проксируют
запрос на нужный локальный порт. Открытие этих диапазонов в Windows не требуется и
создаёт ненужный обход публичного reverse proxy.

## 3. Запустите установку

```sh
curl -fsSL https://raw.githubusercontent.com/blyaxyz/router-support/main/bootstrap-server.sh | sudo bash
```

Установщик обнаружит WSL, проверит PID 1 и попросит подтвердить, что Windows networking
уже настроен. Для неинтерактивного режима требуется явный параметр `--allow-wsl` у
`deploy/install-server.sh`.

Перед Certbot установщик создаёт временный challenge-файл и получает его через
публичный домен. Если цепочка интернет/Windows/WSL не возвращает точное содержимое,
установка останавливается и откатывается до обращения к Let’s Encrypt. В сетях без NAT
loopback проверку можно обойти параметром `--skip-public-http-check`, но только после
успешного запроса того же URL с внешнего устройства, например через мобильный интернет.

Каталог `/run/sshd` создаётся через `systemd-tmpfiles`; запускать `/run/sshd` как
команду не нужно. Сервис Apache в Debian/WSL называется `apache2.service`:

```sh
systemctl status apache2
systemctl status ssh
```

Официальные материалы Microsoft:

- [WSL networking](https://learn.microsoft.com/windows/wsl/networking)
- [Use systemd in WSL](https://learn.microsoft.com/windows/wsl/systemd)
