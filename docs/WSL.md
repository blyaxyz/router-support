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

После `wsl.exe --shutdown` разрешите входящие порты в PowerShell от администратора:

```powershell
New-NetFirewallHyperVRule -Name "RouterSupportHTTP" -DisplayName "Router Support HTTP" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 80
New-NetFirewallHyperVRule -Name "RouterSupportHTTPS" -DisplayName "Router Support HTTPS" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 443
```

Отдельно разрешите выбранный публичный SSH-порт.

### WSL 2 NAT: portproxy

В PowerShell от администратора получите текущий адрес WSL и создайте перенаправления:

```powershell
$WslIp = ((wsl.exe hostname -I).Trim() -split '\s+')[0]
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=80 connectaddress=$WslIp connectport=80
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=443 connectaddress=$WslIp connectport=443
New-NetFirewallRule -DisplayName "Router Support HTTP HTTPS" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80,443
```

Адрес WSL в NAT-режиме может измениться после перезапуска. В этом случае правила
`portproxy` необходимо обновлять автоматически при старте Windows. Для SSH создайте
аналогичное правило с публичного Windows-порта на SSH-порт внутри WSL.

Проверьте, что `connectaddress` совпадает с текущим адресом:

```powershell
netsh interface portproxy show v4tov4
$WslIp = ((wsl.exe hostname -I).Trim() -split '\s+')[0]
Write-Host $WslIp
Test-NetConnection -ComputerName $WslIp -Port 80
```

Если TCP-соединение с публичным IP принимается, но HTTP не возвращает ответ, чаще всего
`portproxy` указывает на старый WSL IP. Удалите старое правило и создайте его заново с
актуальным `$WslIp`.

Если Windows находится за роутером или firewall облачного провайдера, `80`, `443` и
публичный SSH-порт нужно дополнительно направить на Windows-хост.

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
