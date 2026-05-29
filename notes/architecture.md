# Архитектурные решения

## Что выбрано и почему

Один Reality на `0.0.0.0:443` без nginx-stream-роутера. Stream нужен, когда
инбаундов 3+ и они делят 443 по SNI. Для одного Reality — лишний слой.

Cloudflare-путь (жёлтая тучка) отброшен. РКН режет диапазоны CF. Прямое
подключение через серую тучку надёжнее.

SNI donor — большой публичный сайт с TLS 1.3 + HTTP/2 (oracle.com,
microsoft.com). Self-steal на свой домен работает, но только пока домен
не светится в чёрных списках.

## Hysteria2 (опция на будущее)

Отдельный инбаунд в 3x-ui:

- Protocol: hysteria2
- Listen: 0.0.0.0, Port: 443 (UDP, не конфликтует с Reality TCP)
- Cert: `/etc/ssl/appaz/fullchain.pem` и `/etc/ssl/appaz/privkey.pem`
- Obfs: salamander с любым паролем
- Masquerade: `https://www.oracle.com`

Hysteria2 даёт UDP-альтернативу на случай блокировки 443/tcp.
