# Quickstart — развёртывание с нуля

Этот документ — для будущего тебя, если ты забыл «как поднять это всё заново».

## Что получится в итоге

VPN-сервер замаскированный под легитимный сайт. Снаружи это HTTPS-сайт `appaz` (cloud gaming startup), внутри секретные пути ведут к VLESS+WS и Hysteria2.

## Что нужно заранее

1. **VPS** на Ubuntu 22.04 или 24.04 (минимум 1 vCPU, 1 GB RAM, 20 GB)
2. **Домен** на Cloudflare с **серой тучкой** (DNS-only). Например `appaz.xyz`
3. **Cloudflare API Token** с правами `Zone:DNS:Edit` для этого домена
4. **A-записи** в DNS:
   - `appaz.xyz` → IP сервера
   - `www.appaz.xyz` → IP сервера
   - `api.appaz.xyz` → CF Worker (отдельная запись, **жёлтая** тучка)

## Развёртывание

```bash
# 1. Подключиться по SSH к новому серверу
ssh root@НОВЫЙ_IP

# 2. Клонировать репозиторий
apt update && apt install -y git
git clone https://github.com/MuhammadAmadi/appaz-vpn.git /opt/appaz-vpn
cd /opt/appaz-vpn

# 3. Запустить установщик
bash deploy/deploy.sh
```

Скрипт спросит:
- Какие компоненты ставить (Y/n для каждого из 7)
- Домен и email для Let's Encrypt
- Cloudflare API Token (если выбрал CF DNS-01)
- Логин/пароль для 3proxy (если ставишь его)
- Whitelist IP для 3proxy

После завершения скрипта останется **создать инбаунды в 3x-ui панели руками** — список в финальном выводе скрипта.

## Неинтерактивный режим (для повторного запуска)

```bash
DOMAIN=appaz.xyz \
EMAIL=type.92@mail.ru \
CF_TOKEN=ваш-токен \
PROXY_USER=appaz \
PROXY_PASS=ваш-пароль \
PROXY_ALLOWED_IP=1.2.3.4 \
bash deploy/deploy.sh --auto
```

## Создание инбаундов в 3x-ui (после deploy.sh)

Открой панель `https://SERVER:RANDOM_PORT/RANDOM_PATH` (порт и путь из вывода установщика 3x-ui).

Создай 6 инбаундов:

| Remark | Port | Listen | Protocol | Network | Path | SNI |
|---|---|---|---|---|---|---|
| NL WS | 10000 | 127.0.0.1 | vless | ws | /api/render/stream | — |
| NL WS 2 | 10005 | 127.0.0.1 | vless | ws | /ws-vpn-2 | — |
| NL HYSTERIA | 443/udp | — | hysteria2 | — | — | www.cloudflare.com |
| NL HYSTERIA 4G | 1443/udp | — | hysteria2 | — | — | www.cloudflare.com |
| NL VLESS | 4443/tcp | — | vless | tcp | — | www.sony.com (Reality) |
| NL GRPC | 2053/tcp | — | vless | grpc | /grpc | — |

**Важно**: для WS-инбаундов (10000 и 10005) укажи **External Proxy** = `tls://www.appaz.xyz:443` чтобы панель генерировала правильные клиентские ссылки.

## Cloudflare Worker для формы

Форма Apply отправляет POST на `https://api.appaz.xyz/access`, который проксируется через наш nginx (см. `nginx/appaz.conf` секция `/api/apply/access`).

Worker должен принимать POST `/access` и:
1. Парсить form-data
2. Отправлять письмо через CF Email Routing на твою почту
3. Возвращать `{"success":true,"message":"Application received"}`

Подробнее в `docs/02-architecture.md`.

## Что делать если что-то пошло не так

См. `docs/03-troubleshooting.md` (известные грабли) и `docs/04-recovery.md` (восстановление).
