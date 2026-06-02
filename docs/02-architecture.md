# Архитектура

## Концепция «Щит из nginx»

Снаружи сервер выглядит как обычный HTTPS-сайт `appaz.xyz` — лендинг закрытой бета-программы cloud gaming стартапа. Никаких намёков на VPN.

Внутри nginx прячет два VLESS+WS канала под секретными путями и пропускает форму Apply через прокси на Cloudflare Worker. Параллельно сервер слушает Hysteria2 на 443/UDP (TCP и UDP не конфликтуют), VLESS Reality на 4443 и VLESS gRPC на 2053.

## Сетевая схема
┌───────────────────────────────────────┐
                │       Клиенты (РФ, без VPN)           │
                └──────────────┬────────────────────────┘
                               │
                               ▼  HTTPS / TLS 1.2-1.3
                ┌─────────── 443/tcp ───────────┐
                │                                │
                │       nginx 1.30 (фронт)       │
                │                                │
                │  GET /          → /var/www/appaz/index.html (заглушка)
                │  POST /api/auth/login → 401 JSON (ловушка)
                │  POST /api/apply/access → https://api.appaz.xyz/access (CF Worker)
                │  WS /api/render/stream → 127.0.0.1:10000 (Xray VLESS)
                │  WS /ws-vpn-2          → 127.0.0.1:10005 (Xray VLESS)
                │                                │
                └────────────────────────────────┘

                ┌─── 443/udp ───┐  Hysteria2 main
                │  Xray         │  donor SNI: www.cloudflare.com
                └───────────────┘

                ┌─── 1443/udp ──┐  Hysteria2 backup (4G mobile)
                │  Xray         │
                └───────────────┘

                ┌─── 4443/tcp ──┐  VLESS Reality
                │  Xray         │  donor SNI: www.sony.com
                └───────────────┘

                ┌─── 2053/tcp ──┐  VLESS gRPC
                │  Xray         │
                └───────────────┘

                ┌─── 8888/tcp ──┐  3proxy (HTTP-релей для TG-бота)
                │  whitelist+пароль
                └───────────────┘

                ┌─── 2083/tcp ──┐  3x-ui панель управления
                │  (random path)│
                └───────────────┘

                ┌─── 2096/tcp ──┐  3x-ui subscription endpoint
                └───────────────┘
## Защита

- **TLS 1.2 + 1.3**, server_tokens off, скрытие /\.git, /\.env
- **limit_conn 100/IP** на сервер целиком (защита от slow-DDoS)
- **limit_req 30 req/s** на /, **10 req/min** на /api/auth/login и /api/apply/access
- **fail2ban**: 4 jail (sshd + nginx-badbots + nginx-tlsjunk + nginx-authabuse)
- **sysctl**: SYN-cookies, rp_filter, ICMP-фильтры, увеличенные TCP-буферы
- **ufw**: rate-limit для SSH (22), открыты только нужные порты, 3proxy:8888 только с whitelist IP

## Защита от блокировок

- **Серая тучка Cloudflare** для основного домена — РКН не режет (наш собственный IP, не CF-диапазон)
- **Жёлтая тучка** только для `api.appaz.xyz` (CF Worker) — он не критичен, и его форма проксируется через наш сервер
- **Hysteria2 donor SNI** = `www.cloudflare.com` — снаружи выглядит как обычный HTTP/3 запрос к CF
- **VLESS Reality donor SNI** = `www.sony.com` — снаружи выглядит как TLS handshake к Sony

## Зачем 3proxy

Telegram-бот на российском сервере не может достучаться до серверов Telegram (заблокированы РКН). Он подключается к `http://USER:PASS@SERVER:8888` (наш 3proxy в Амстердаме) и через него ходит наружу. Двойная защита: whitelist по IP + Basic auth.

## Cloudflare Worker для формы

Браузер клиента → POST на `https://www.appaz.xyz/api/apply/access` (наш домен, серая тучка, **проходит РКН**) → nginx проксирует на `https://api.appaz.xyz/access` (CF Worker) → Worker отправляет письмо через CF Email Routing на твою почту.

Без этой прослойки клиент в РФ не смог бы отправить форму (РКН режет CF-диапазоны при прямом обращении), и стартапу было бы невозможно получать заявки.
