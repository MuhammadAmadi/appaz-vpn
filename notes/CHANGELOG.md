# CHANGELOG

История значимых изменений архитектуры.

## 2026-06 — v2: Production-ready

### Добавлено
- **CF Worker для формы Apply**: форма заявок теперь не падает у клиентов в РФ. Прокси через nginx → `api.appaz.xyz` (CF) → CF Email Routing → почта
- **3proxy на 8888/tcp**: HTTP-релей для Telegram-бота с российского сервера. Двойная защита: whitelist по IP + Basic auth
- **Второй WS-канал** (`/ws-vpn-2` → 10005): бэкап для случаев когда первый отвалится
- **Hysteria2 backup** на 1443/udp: альтернатива основному 443/udp для мобильных юзеров
- **fail2ban для nginx**: 3 дополнительных jail (nginx-badbots, nginx-tlsjunk, nginx-authabuse)
- **sysctl-hardening**: SYN-cookies, rp_filter, ICMP-фильтры, увеличенные TCP-буферы
- **ufw rate-limit для SSH**: limit вместо allow для порта 22
- **limit_conn 100/IP** на nginx-сервер, **limit_req** на критичные локации
- **TLS 1.2 + 1.3** (раньше только 1.3)
- **nginx 1.30.2** из официального репо (раньше 1.18 из Ubuntu)
- **docs/**: пять документов (quickstart, architecture, troubleshooting, recovery, secrets)
- **deploy.sh**: интерактивный установщик с 7 опциональными шагами + неинтерактивный режим

### Убрано
- **VLESS Reality как основной канал**: оказался нестабилен против ТСПУ. Оставлен как бэкап на 4443
- **nginx-stream SNI-роутер**: избыточен для одного Reality-инбаунда, создавал петлю
- **notes/reality-setup.md**: устарел, заменён на актуальные docs/

### Изменено
- **Форма Apply**: action был `https://api.appaz.xyz/access`, стал `/api/apply/access` (через наш nginx)
- **Маскировка**: вместо JSON-страницы поднят полноценный лендинг appaz (1323 строки HTML)
- **PostgreSQL для 3x-ui**: раньше SQLite, теперь PostgreSQL

### Известные баги (см. docs/03-troubleshooting.md)
- 3x-ui v3.2.0 ломает Reality SNI markdown-обёрткой
- 3x-ui v3.x показывает устаревшие порты в редакторе клиента (БД корректна)
- 3proxy 0.9.6 deb требует glibc 2.38 — собираем из исходников

## 2026-05 — v1: Initial

- nginx + сайт-заглушка
- VLESS Reality на 443/tcp
- 3x-ui панель
- Базовая защита через ufw + fail2ban (только sshd)
