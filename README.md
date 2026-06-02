# appaz-vpn

VPN-сервер замаскированный под легитимный HTTPS-сайт. Снаружи — лендинг закрытого бета-стартапа cloud gaming. Внутри секретные пути ведут к VLESS+WS и Hysteria2.

## Архитектура (TL;DR)
Клиенты в РФ
↓ HTTPS
↓ Серая тучка Cloudflare (DNS-only, не CF-диапазон)
nginx 1.30 на 443/tcp
├─ GET /                          → сайт-заглушка appaz
├─ POST /api/auth/login           → 401 (ловушка)
├─ POST /api/apply/access         → CF Worker (форма заявок)
├─ WS /api/render/stream          → 127.0.0.1:10000 (VLESS канал 1)
└─ WS /ws-vpn-2                   → 127.0.0.1:10005 (VLESS канал 2)
Параллельно на сервере:
├─ Hysteria2 на 443/udp (donor SNI: www.cloudflare.com)
├─ Hysteria2 на 1443/udp (бэкап для мобильного интернета)
├─ VLESS Reality на 4443/tcp (donor SNI: www.sony.com)
├─ VLESS gRPC на 2053/tcp
├─ 3proxy на 8888/tcp (HTTP-релей для TG-бота, whitelist+пароль)
└─ 3x-ui панель на 2083/tcp + подписка на 2096/tcp

Подробнее см. [`docs/02-architecture.md`](docs/02-architecture.md).

## Структура репо
.
├── deploy/
│   └── deploy.sh                 # Универсальный установщик (интерактив + --auto)
├── nginx/
│   ├── nginx.conf                # Главный конфиг с зонами rate-limit
│   └── appaz.conf                # Сайт + WS-каналы + CF-прокси
├── website/
│   └── index.html                # Сайт-заглушка appaz (1323 строк)
├── security/
│   ├── 99-appaz-hardening.conf   # sysctl: SYN-cookies, rp_filter, буферы
│   ├── fail2ban-jail.local       # 4 jail (sshd + 3 nginx)
│   ├── nginx-badbots.conf        # фильтр: сканеры PHP/CGI/wp-admin
│   ├── nginx-tlsjunk.conf        # фильтр: \x16 мусор (raw TLS на HTTP)
│   └── nginx-authabuse.conf      # фильтр: GET/HEAD на /api/auth/login
├── proxy/
│   ├── 3proxy.cfg.template       # Шаблон с PROXY_USER/PASSWORD/ALLOWED_IP
│   └── 3proxy.service            # systemd-юнит с ReadWritePaths
├── docs/
│   ├── 01-quickstart.md          # Развёртывание с нуля
│   ├── 02-architecture.md        # Как и почему всё устроено
│   ├── 03-troubleshooting.md     # Известные грабли
│   ├── 04-recovery.md            # Что делать если упало
│   └── 05-secrets-template.md    # Шаблон для записи кредов
├── notes/
│   └── CHANGELOG.md              # История значимых изменений
├── .gitignore
└── README.md

## Развёртывание на новом сервере

```bash
apt update && apt install -y git
git clone https://github.com/MuhammadAmadi/appaz-vpn.git /opt/appaz-vpn
cd /opt/appaz-vpn
bash deploy/deploy.sh
```

Скрипт интерактивный: спросит какие компоненты ставить (7 шагов, каждый Y/n), домен, email, Cloudflare API Token, и т.д. После завершения останется создать инбаунды в 3x-ui панели руками — финальный summary покажет точные параметры.

Для автоматизации есть неинтерактивный режим — см. [`docs/01-quickstart.md`](docs/01-quickstart.md).

## Что нужно заранее

1. VPS на Ubuntu 22.04/24.04
2. Домен на Cloudflare с серой тучкой
3. Cloudflare API Token (Zone:DNS:Edit)
4. A-записи: `appaz.xyz` и `www.appaz.xyz` на IP сервера, `api.appaz.xyz` на CF Worker (жёлтая тучка)

## Защита

- TLS 1.2 + 1.3, server_tokens off, HSTS, CSP
- limit_conn 100/IP + limit_req 30 req/s на /
- fail2ban (4 jail) с auto-ban сканеров
- sysctl-hardening (SYN-flood, ICMP, rp_filter)
- ufw: открыты только нужные порты, SSH с rate-limit
- 3proxy с whitelist по IP + Basic auth

## Обновление сертификата

Автоматически через cron (acme.sh). Принудительно:
```bash
export CF_Token="..."
/root/.acme.sh/acme.sh --renew -d appaz.xyz --force
```

## Безопасность

- **Никогда** не коммить файлы с реальными секретами. См. [`docs/05-secrets-template.md`](docs/05-secrets-template.md).
- Файлы с расширениями `*.key`, `*.pem`, `*.crt`, `*.db`, `*.env` уже в `.gitignore`.
- После установки **закрой SSH-вход по паролю** (используй ключи). Подробнее в `docs/01-quickstart.md`.

## Лицензия

Приватный проект. Все права защищены.
