# Быстрый запуск

## 1. Подготовьте DNS и firewall

Создайте две A-записи на публичный IPv4 VPS:

```text
support.example.com    -> 203.0.113.10
*.support.example.com  -> 203.0.113.10
```

Откройте входящие TCP-порты `22`, `80`, `443`. Диапазон reverse-портов
`22001–22999` наружу открывать нельзя: они слушают только `127.0.0.1`.

## 2. Установите сервер одним скриптом

На чистом Debian 12/13:

```sh
sudo ./bootstrap-server.sh
```

В конце установки скрипт показывает `ENGINEER ACCESS TOKEN`. Обязательно сохраните
его: без этого токена войти в веб-панель невозможно. Копия остаётся на сервере в
`/etc/router-support/backend.env`, доступ к файлу имеет только `root`.

Bootstrap спросит GitHub URL и ветку, установит Git/curl/CA, скачает проект и запустит
quiz. В quiz можно указать собственный домен либо только публичный IPv4 — тогда будет
выпущен короткоживущий Let’s Encrypt сертификат непосредственно на IP и автоматически
сформирован домен `support.<IP>.sslip.io` для сервисных поддоменов.

Пока репозиторий не опубликован, можно использовать release-архив:

Загрузите release-архив на Debian 12/13, распакуйте и выполните от root:

```sh
./deploy/install-server.sh
```

Quiz установит Apache, OpenSSH, Python venv, Certbot, зависимости backend, создаст
пользователя и ключи, настроит systemd, firewall-зависимые порты и Let’s Encrypt.

Получите токены:

```sh
grep '^ROUTER_SUPPORT_ENGINEER_TOKEN=' /etc/router-support/backend.env
grep '^ROUTER_SUPPORT_BOOTSTRAP_TOKEN=' /etc/router-support/backend.env
```

## 3. Установите агент

С рабочей станции:

```sh
./scripts/deploy-router-agent.sh root@192.168.1.1 https://support.example.com
```

Токен вводится скрыто и не передаётся в аргументах удалённых процессов. После
регистрации агент удаляет общий bootstrap-token с роутера.

При ручной установке можно запустить `./openwrt-agent/install.sh` без аргументов:
скрипт сам спросит HTTPS-адрес панели и скрыто запросит bootstrap-token.

## 4. Выпустите сертификаты сервисов

После появления роутера в базе выполните на VPS:

```sh
/opt/router-support/deploy/sync-service-domains.sh
```

## 5. Откройте панель

Перейдите на `https://support.example.com`, вставьте инженерный токен и запустите
поддержку. Появятся LuCI, V2RayA и SSH.

