# Troubleshooting — известные грабли

Сборник проблем, которые мы уже наступали, и как их обходить. Если что-то отвалилось — сначала сюда.

## 3x-ui v3.2.0 — баг с markdown в SNI

**Симптом**: Reality-инбаунд перестаёт работать после нажатия кнопки «Обновить SNI» (Get latest SNI) в панели.

**Причина**: панель вставляет в поле `dest` markdown-строку вида `[domain.com](https://domain.com)` вместо чистого `domain.com:443`.

**Лечение**: правка через psql напрямую, минуя UI:
```bash
sudo -u postgres psql -d xui -c "
  UPDATE inbounds SET stream_settings = REPLACE(stream_settings,
    '[www.sony.com](https://www.sony.com)', 'www.sony.com:443')
  WHERE id = 7;"
systemctl restart x-ui
```

**Профилактика**: никогда не жми кнопку обновления SNI в UI. Если меняешь SNI — вписывай руками с клавиатуры.

## 3x-ui v3.x — устаревшие порты в редакторе клиента

**Симптом**: при создании/редактировании клиента в списке inbound показываются **старые** порты (например `8443`, `9000`), которых на самом деле уже нет в Inbounds.

**Причина**: косметический баг панели v3.2.0. БД при этом корректна — `client_inbounds(client_id, inbound_id)` хранит только FK. Подписки и happ получают правильные конфиги.

**Лечение**: игнорировать UI, проверять реальную работу через подписку и `ss -tlnp`. При большом желании поможет `systemctl restart x-ui` + Ctrl+Shift+R в браузере.

## Markdown-обёртка при копировании доменов из чата

**Симптом**: вставил домен из мессенджера в поле 3x-ui — Reality сломался.

**Причина**: автолинковка в чате превращает `domain.com` в `[domain.com](https://domain.com)`. При копировании может попасть и markdown-разметка.

**Профилактика**: всегда печатай домены **руками с клавиатуры**, не копируй из ассистента/чата.

## Reality fallback target — петля через nginx

**Симптом**: Reality иногда отвечает но не передаёт данные, в логах nginx появляются self-loop запросы.

**Причина**: в Reality-инбаунде fallback target указан на `www.appaz.xyz:443`, который и есть наш nginx. Получается петля Reality → nginx → Reality.

**Лечение**: fallback target должен указывать **либо** на `127.0.0.1:8443` (отдельный локальный nginx для fallback), **либо** на чужой donor-домен (`www.sony.com:443`). Никогда на свой собственный nginx-фронт.

## WS-канал отвечает 502 Bad Gateway

**Симптом**: `curl https://domain/api/render/stream` возвращает 502.

**Причины**:
1. Xray не поднял инбаунд — изменения портов в панели не подхватились
2. Инбаунд listen=0.0.0.0 вместо 127.0.0.1, и nginx не достучался по правильному адресу

**Диагностика**:
```bash
ss -tlnp | grep -E ':(10000|10005)'
sudo -u postgres psql -d xui -c "SELECT id, remark, port, listen FROM inbounds WHERE port IN (10000, 10005);"
```

Если порт не слушает — `systemctl restart x-ui`. Если listen неправильный — поправь в панели и нажми Save (повторно даже если ничего не менял — это форсит перезапись).

## CF Worker возвращает 405 через nginx прокси, но 200 напрямую

**Симптом**: `curl POST https://www.appaz.xyz/api/apply/access` → 405. `curl POST https://api.appaz.xyz/access` → 200.

**Причина**: nginx по умолчанию **меняет метод на GET** при некоторых конфигурациях `proxy_pass`. Нужно явно сохранить метод.

**Лечение**: в nginx-локации добавить `proxy_method $request_method;`. См. `nginx/appaz.conf` секция `/api/apply/access`.

## Жёлтая тучка Cloudflare режется РКН

**Симптом**: пользователи в РФ не могут открыть `https://www.appaz.xyz` если домен через CF (жёлтая тучка).

**Причина**: РКН блокирует целые подсети Cloudflare. Жёлтая тучка = трафик идёт через CF.

**Лечение**: используй **серую тучку** (DNS-only) для основного домена. CF будет только резолвить, трафик пойдёт на твой IP напрямую.

Для `api.appaz.xyz` (CF Worker) жёлтая тучка нужна — но он проксируется через наш сервер, юзеру не видна.

## 3proxy не стартует — Read-only file system

**Симптом**: `journalctl -u 3proxy` показывает `/var/log/3proxy/...: Read-only file system`.

**Причина**: systemd-юнит с `ProtectSystem=full` держит `/usr`, `/boot`, `/etc` read-only. Лог-каталогу 3proxy (`/var/log/3proxy`) и pid-файлу (`/var/run/3proxy.pid`) нужна явная запись.

**Лечение**: в `[Service]` юнита:
```ini
ReadWritePaths=/var/log/3proxy /var/run
```

Уже добавлено в `proxy/3proxy.service`.

## 3proxy не стартует — status=226/NAMESPACE, "Failed to set up mount namespacing"

**Симптом**: `systemctl status 3proxy` → `code=exited, status=226/NAMESPACE`. В `journalctl -xeu 3proxy`:
```
Failed to set up mount namespacing: /usr/local/3proxy/logs: No such file or directory
```

**Причина**: `ReadWritePaths=` в systemd падает с 226/NAMESPACE, если хотя бы один из перечисленных путей физически не существует на диске — systemd не может подготовить bind-mount для несуществующей директории. В старой версии юнита в `ReadWritePaths` был путь `/usr/local/3proxy/logs` (расчёт на симлинк, которого `deploy.sh` никогда не создавал).

**Лечение**: убрать несуществующий путь из `ReadWritePaths` (оставить только реально создаваемые `deploy.sh` каталоги: `/var/log/3proxy` и `/var/run`). Уже исправлено в `proxy/3proxy.service`.

Если правите юнит вручную на уже установленном сервере:
```bash
systemctl edit --full 3proxy.service   # убрать /usr/local/3proxy/logs из ReadWritePaths
systemctl daemon-reload
systemctl restart 3proxy
```

## 3proxy package требует glibc 2.38 а у нас 2.35

**Симптом**: `dpkg -i 3proxy-0.9.6.x86_64.deb` → dependency error, libc6 >= 2.38.

**Причина**: deb-пакет 3proxy 0.9.6 собран против Ubuntu 24, а на Ubuntu 22 glibc 2.35.

**Лечение**: собирать из исходников. См. `deploy/deploy.sh` секция «Сборка 3proxy».

## Telegram-бот выдаёт "event not found" при подключении к 3proxy

**Симптом**: `curl -x "http://user:pass!@host:port" ...` → `bash: !@host: event not found`.

**Причина**: bash интерпретирует `!` как history expansion.

**Лечение**: используй одинарные кавычки `curl -x 'http://user:pass!@host:port' ...`. В конфигах Python/Node.js бота никаких кавычек не нужно — там это просто строка.

## happ-клиент держит «петлю переподключений» (сотни 101 в access.log)

**Симптом**: в `tail /var/log/nginx/access.log` видно сотни WS-апгрейдов в секунду, размер ответа всегда 4 байта.

**Причина**: VLESS-handshake фейлится после WS-upgrade'а. Клиент закрывает соединение и тут же открывает новое. 4 байта = WebSocket close frame.

**Диагностика**: проверить настройки клиента — UUID, path, host, flow (должен быть пустой для WS), network=ws. И что в happ роутинге трафик не уходит через `direct` outbound (мимо VPN).

**Лечение**: переимпортировать клиентскую ссылку с нуля. Если happ-роутинг сложный — попробовать v2RayN на ПК (он импортирует чистую VLESS-ссылку без накруток).

## 3x-ui ставится на SQLite несмотря на шаг «(с PostgreSQL)» в визарде

**Симптом**: после установки `x-ui settings`/report.sh показывают пустые `user`, `panel.url` без порта и пути (`https://IP://`). Отчёт в мастер-сервер приходит с дырами.

**Причина**: официальный установщик `mhsanaei/3x-ui` спрашивает выбор БД (SQLite/PostgreSQL) интерактивно, но т.к. `deploy.sh` вызывает его с `stdin`, не подключённым к TTY, установщик уходит в свой `NONINTERACTIVE`-режим и по умолчанию ставит SQLite — независимо от того, что напечатано в heredoc. `lib/report.sh` же всегда читает настройки через `sudo -u postgres psql -d xui`, что при SQLite возвращает пусто.

**Лечение**: передавать `XUI_DB_TYPE=postgres` в окружении перед вызовом установщика — тогда он сам ставит и настраивает локальный PostgreSQL. Уже добавлено в `deploy/deploy.sh` (шаг «Установка 3x-ui»).

Если сервер уже установлен на SQLite и переустанавливать не хочется — мигрировать вручную через `x-ui` CLI (`x-ui migrate` не существует «на лету»; проще: `x-ui uninstall` и переустановить с фиксом) либо просто мириться с тем, что `report.sh` не сможет прочитать `user`/`port`/`path` для этого сервера.

## Отчёт в Telegram приходит с битым JSON в поле `ipv6`

**Симптом**: в JSON-отчёте (`report.sh`) поле `"ipv6"` содержит вместо адреса кусок HTML вроде `403 Forbidden`.

**Причина**: `curl -s6 -m 5 ifconfig.me` на сервере без реальной IPv6-связности иногда не падает с ошибкой (что ушло бы в `|| echo ""`), а получает HTTP-ответ 403 от какого-то прокси/CDN на пути — и это тело ответа подставляется в JSON как есть, ломая кавычки/переносы строк.

**Лечение**: `report.sh` теперь проверяет, что ответ похож на реальный IP (regex), и если нет — оставляет поле пустым. Уже исправлено.

## fail2ban банит самого себя

**Симптом**: SSH перестал работать с твоего IP.

**Лечение**: на сервере (если есть доступ через консоль хостера):
```bash
fail2ban-client unban ТВОЙ_IP
```

**Профилактика**: добавь свой стационарный IP в whitelist в `/etc/fail2ban/jail.local`:
```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 1.2.3.4
```
