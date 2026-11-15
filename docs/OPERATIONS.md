# Эксплуатация и диагностика

## Обновление

Распакуйте новый release на VPS и выполните:

```sh
sudo ./deploy/update-server.sh
```

Скрипт останавливает только backend, обновляет код и зависимости, затем проверяет
`/healthz`. База, ключи, токены, Apache и sshd не перезаписываются.

После изменения OpenWrt-агента повторно выполните workstation-скрипт установки. UUID и
индивидуальный ключ сохраняются.

## Резервная копия

```sh
sudo /opt/router-support/deploy/backup-server.sh
```

Архив создаётся в `/var/backups/router-support` с правами `0600`. Он содержит секреты,
SQLite и SSH-ключи, поэтому храните его зашифрованным и отдельно от VPS.

## Удаление агента с роутера

Безопасное удаление сохраняет UUID, device-token и индивидуальный ключ для возможной
повторной установки:

```sh
./scripts/remove-router-agent.sh root@192.168.1.1
```

Полное удаление идентичности:

```sh
./scripts/remove-router-agent.sh root@192.168.1.1 --purge
```

На самом роутере доступны те же режимы:

```sh
/usr/sbin/router-support-uninstall
/usr/sbin/router-support-uninstall --purge
```

Оба режима останавливают туннель, отключают `procd`, удаляют support-key из Dropbear и
только соответствующую запись VPS из `known_hosts`. `--purge` дополнительно удаляет
UUID, device-token и приватный ключ. Запись в центральной базе не удаляется
автоматически: устройство перейдёт в offline.

## Логи

VPS:

```sh
journalctl -u router-support -f
journalctl -u ssh --since today
tail -f /var/log/apache2/router-support-error.log
```

OpenWrt:

```sh
logread -e router-support
/etc/init.d/router-support status
```

## Роутер online, но support не запускается

Проверьте:

```sh
ss -lnt | grep 22001
cat /opt/router-support/data/authorized_keys
journalctl -u router-support -n 100 --no-pager
```

На роутере должен работать один `dbclient`. Если reverse-порт не появился, проверьте
доступ к VPS:22, host key и `logread`.

## LuCI/V2RayA возвращает ошибку

Убедитесь, что support-сессия активна и локальный сервис слушает ожидаемый порт:

```sh
netstat -lntp | grep -E ':80|:2017|:2018'
```

После добавления нового роутера обязательно выполните `sync-service-domains.sh`.

## Веб-SSH не открывается

Проверьте модуль и WebSocket-маршрут:

```sh
apache2ctl -M | grep proxy_wstunnel
grep '/api/terminal/' /etc/apache2/sites-enabled/router-support*
```

SSH доступен только во время активной support-сессии. Ticket действует 30 секунд и
используется один раз.

## Short-lived сертификат на IP

```sh
systemctl status router-support-certbot.timer
journalctl -u router-support-certbot.service --since today
/opt/router-support-certbot/bin/certbot certificates
```

Timer запускается дважды в сутки; Certbot обновляет сертификат в рекомендованное ACME
окно и выполняет reload Apache через deploy-hook. Публичный порт `80` должен оставаться
доступным для `http-01` challenge.

## Telemt на публичном порту 443

Проверка управляемых маршрутов и резервной копии:

```sh
grep -A20 'BEGIN ROUTER SUPPORT' /etc/telemt/telemt.toml
ls -l /etc/telemt/telemt.toml.router-support-backup
```

Повторная синхронизация сертификата и маршрутов выполняется обычной командой:

```sh
/opt/router-support/deploy/sync-service-domains.sh
```

Скрипт перезапускает Telemt, проверяет его systemd-состояние и открывает `/healthz`
через локальный SNI-маршрут. При любой ошибке прежний TOML восстанавливается.

Для полного ручного отката интеграции:

```sh
cp -a /etc/telemt/telemt.toml.router-support-backup /etc/telemt/telemt.toml
systemctl restart telemt
```

## Безопасность

- смените переданные или временные root-пароли;
- отключите password login root после настройки ключевого доступа;
- не открывайте `22001–22999` в публичном firewall;
- храните `backend.env`, backup и support private key как секреты;
- регулярно обновляйте Debian/OpenSSH/OpenWrt;
- завершайте support-сессию сразу после работы.

