# Настройка Reality в 3x-ui

После установки 3x-ui войди в панель и создай Inbound.

## Базовые поля

- Protocol: VLESS
- Listen: 0.0.0.0 (или пусто)
- Port: 443
- Network: tcp
- Security: reality
- Flow клиента: xtls-rprx-vision

## Reality-блок

Server Names — впечатай руками, например `www.oracle.com`. НЕ нажимай кнопку
обновления рядом с полем — в v3.2.0 это баг, превращающий значение в markdown.

Dest/Target — тоже руками, `www.oracle.com:443`.

Private/Public key — нажми Get New Cert.

Short IDs — нажми generate.

## Проверка после Save

    python3 -c "import json; c=json.load(open('/usr/local/x-ui/bin/config.json')); r=[i for i in c['inbounds'] if i.get('protocol')=='vless'][0]['streamSettings']['realitySettings']; print(repr(r['serverNames']))"

Должно показать `['www.oracle.com']` — без скобок внутри строки.

## Если markdown пролез (баг v3.2.0)

Лечится прямой правкой БД:

    systemctl stop x-ui
    sqlite3 /etc/x-ui/x-ui.db "UPDATE inbounds SET stream_settings = json_set(json_set(stream_settings, '\$.realitySettings.serverNames', json_array('www.oracle.com')), '\$.realitySettings.target', 'www.oracle.com:443') WHERE id = 1;"
    systemctl start x-ui

## Клиенты

Скачай URL/QR из панели, импортируй в v2rayNG / v2RayN / v2RayTun.
В URL должен быть `sni=www.oracle.com` без скобок.
