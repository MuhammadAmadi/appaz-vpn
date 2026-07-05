#!/bin/bash
# ============================================================================
# appaz-vpn deploy.sh
# Универсальный установщик для Ubuntu 22.04/24.04
# Ставит: nginx + LE + 3x-ui + 3proxy + fail2ban + sysctl + ufw
# ----------------------------------------------------------------------------
# Использование:
#   sudo bash deploy.sh                       # интерактивный режим
#   sudo bash deploy.sh --auto                # неинтерактивный, всё ставим
#   sudo DOMAIN=appaz.xyz CF_TOKEN=... bash deploy.sh --auto
# ============================================================================

set -e
set -o pipefail

# ── Цвета и хелперы ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
step() { echo -e "\n${BLUE}═══ $* ═══${NC}\n"; }

# Спрашиваем Y/n. По умолчанию Y если параметр Y, иначе N. Поддерживает --auto.
ask_yn() {
    local prompt="$1"; local default="${2:-Y}"; local answer
    if [ "$AUTO" = "1" ]; then echo "[auto] $prompt → $default"; [ "$default" = "Y" ] && return 0 || return 1; fi
    if [ "$default" = "Y" ]; then read -p "$prompt [Y/n] " answer; answer="${answer:-Y}";
    else read -p "$prompt [y/N] " answer; answer="${answer:-N}"; fi
    [[ "$answer" =~ ^[Yy] ]]
}

# Спрашивает строку с дефолтным значением, поддерживает env
ask_str() {
    local prompt="$1"; local var="$2"; local default="${3:-}"; local value
    if [ -n "${!var}" ]; then echo "[env] $var=${!var}"; eval "$var=\"${!var}\""; return; fi
    if [ "$AUTO" = "1" ]; then eval "$var=\"$default\""; echo "[auto] $var=$default"; return; fi
    if [ -n "$default" ]; then read -p "$prompt [$default]: " value; value="${value:-$default}"
    else read -p "$prompt: " value; fi
    eval "$var=\"$value\""
}

# Спрашивает секрет (без эха)
ask_secret() {
    local prompt="$1"; local var="$2"; local value
    if [ -n "${!var}" ]; then echo "[env] $var=*** (hidden)"; eval "$var=\"${!var}\""; return; fi
    if [ "$AUTO" = "1" ]; then err "В режиме --auto нужно передать $var через env"; exit 1; fi
    read -s -p "$prompt: " value; echo
    eval "$var=\"$value\""
}


# ── Подключение библиотек уведомлений (notify.sh + report.sh) ───────────────
SCRIPT_DIR_BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR_BOOT/lib/notify.sh" ] && source "$SCRIPT_DIR_BOOT/lib/notify.sh"
[ -f "$SCRIPT_DIR_BOOT/lib/report.sh" ] && source "$SCRIPT_DIR_BOOT/lib/report.sh"

# Засекаем время старта
SCRIPT_START_TS=$(date +%s)

# Глобальный обработчик ошибок — шлёт в TG при падении скрипта
on_error() {
    local exit_code=$?
    local line_no=$1
    if [ "$exit_code" -ne 0 ]; then
        tg_notify_error "deploy.sh failed (exit $exit_code) at line $line_no" "Host: $(hostname)"
    fi
}
trap 'on_error $LINENO' ERR

# Спрашиваем про TG-уведомления (если ещё не настроены)
setup_tg_notifications() {
    if [ -f /etc/appaz/notify.env ] && [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
        log "TG-уведомления: используются настройки из /etc/appaz/notify.env"
        return 0
    fi
    if ask_yn "Включить Telegram-уведомления о ходе установки?" Y; then
        ask_secret "Telegram bot token" TG_BOT_TOKEN
        ask_str    "Telegram chat ID"   TG_CHAT_ID
        tg_save_config
        log "TG-уведомления настроены и сохранены в /etc/appaz/notify.env"
    else
        log "TG-уведомления отключены"
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi
}

# ── Парсинг аргументов ──────────────────────────────────────────────────────
AUTO=0
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO=1 ;;
        --help|-h)
            cat <<HELP
Usage: $0 [--auto]
Environment variables (для --auto):
  SSH_PORT        порт, на котором слушает sshd (по умолчанию 22)
  DOMAIN          основной домен (например appaz.xyz)
  EMAIL           email для Let's Encrypt
  CF_TOKEN        Cloudflare API Token для DNS-01
  PROXY_USER      логин для 3proxy
  PROXY_PASS      пароль для 3proxy
  PROXY_ALLOWED_IP IP с которого разрешён вход в 3proxy
HELP
            exit 0 ;;
    esac
done

# ── Проверка root ───────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then err "Запусти скрипт от root: sudo bash $0"; exit 1; fi

# ── Проверка ОС ─────────────────────────────────────────────────────────────
if ! command -v apt >/dev/null 2>&1; then err "Только Debian/Ubuntu"; exit 1; fi
OS_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
log "ОС: $(lsb_release -d 2>/dev/null | cut -f2- || cat /etc/os-release | head -1)"

# ── Корень проекта (где deploy.sh) ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
log "Repo root: $REPO_ROOT"

# ── Спрашиваем компоненты заранее, чтобы wizard был «в начале» ──────────────
step "Какие компоненты установить?"
ask_yn "[1/7] Базовые пакеты (curl, git, ufw, build-essential)" Y && INSTALL_BASE=1 || INSTALL_BASE=0
ask_yn "[2/7] sysctl-hardening (защита ядра от SYN-flood/MITM)" Y && INSTALL_SYSCTL=1 || INSTALL_SYSCTL=0
ask_yn "[3/7] ufw + правила (открыть стандартные порты)"       Y && INSTALL_UFW=1 || INSTALL_UFW=0
ask_yn "[4/7] nginx 1.30 + acme.sh + Let's Encrypt сертификат" Y && INSTALL_NGINX=1 || INSTALL_NGINX=0
ask_yn "[5/7] 3x-ui панель (выбор SQLite/PostgreSQL в установщике)" Y && INSTALL_XUI=1 || INSTALL_XUI=0
ask_yn "[6/7] 3proxy (HTTP-релей с whitelist+пароль)"           N && INSTALL_3PROXY=1 || INSTALL_3PROXY=0
ask_yn "[7/7] fail2ban + наши nginx-фильтры"                    Y && INSTALL_FAIL2BAN=1 || INSTALL_FAIL2BAN=0

# ── Параметры ufw (SSH-порт) ─────────────────────────────────────────────────
if [ "$INSTALL_UFW" = "1" ]; then
    step "Параметры ufw"
    # `|| true` обязателен: при дефолтном sshd_config (строка `Port` закомментирована)
    # grep ничего не находит и возвращает 1, что под `set -e`+`pipefail` уронило бы скрипт.
    SSHD_CURRENT_PORT=$(grep -Po '^\s*Port\s+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null | tail -1 || true)
    ask_str "SSH порт (на котором реально слушает sshd)" SSH_PORT "${SSHD_CURRENT_PORT:-22}"
    if [ -n "$SSHD_CURRENT_PORT" ] && [ "$SSHD_CURRENT_PORT" != "$SSH_PORT" ]; then
        warn "sshd сейчас слушает на $SSHD_CURRENT_PORT, а не на $SSH_PORT — проверь, не отрежет ли ufw доступ!"
    fi
fi

# ── Параметры (если nginx или 3proxy будут ставиться) ───────────────────────
if [ "$INSTALL_NGINX" = "1" ]; then
    step "Параметры nginx + SSL"
    ask_str "Основной домен (без www)" DOMAIN "appaz.xyz"
    ask_str "Email для Let's Encrypt"  EMAIL "type.92@mail.ru"
    if ask_yn "Использовать Cloudflare DNS-01 (нужен CF API Token)?" Y; then
        ask_secret "Cloudflare API Token (Zone:DNS:Edit для $DOMAIN)" CF_TOKEN
        SSL_METHOD="cf-dns"
    else
        warn "Без CF DNS-01: certbot HTTP-01 (домен должен резолвиться на этот сервер прямо сейчас)"
        SSL_METHOD="http"
    fi
fi

if [ "$INSTALL_3PROXY" = "1" ]; then
    step "Параметры 3proxy"
    ask_str    "Логин для прокси"               PROXY_USER       "appaz"
    ask_secret "Пароль для прокси"              PROXY_PASS
    ask_str    "Whitelist IP (откуда разрешён вход)" PROXY_ALLOWED_IP "0.0.0.0/0"
fi

# ── Резюме ──────────────────────────────────────────────────────────────────
step "Резюме"
echo "  Base packages:    $([ "$INSTALL_BASE" = "1" ] && echo YES || echo no)"
echo "  sysctl-hardening: $([ "$INSTALL_SYSCTL" = "1" ] && echo YES || echo no)"
if [ "$INSTALL_UFW" = "1" ]; then echo "  ufw:              YES (SSH port=$SSH_PORT)"; else echo "  ufw:              no"; fi
if [ "$INSTALL_NGINX" = "1" ]; then echo "  nginx + LE:       YES (domain=$DOMAIN, method=$SSL_METHOD)"; else echo "  nginx + LE:       no"; fi
echo "  3x-ui:            $([ "$INSTALL_XUI" = "1" ] && echo YES || echo no)"
if [ "$INSTALL_3PROXY" = "1" ]; then echo "  3proxy:           YES (user=$PROXY_USER, whitelist=$PROXY_ALLOWED_IP)"; else echo "  3proxy:           no"; fi
echo "  fail2ban:         $([ "$INSTALL_FAIL2BAN" = "1" ] && echo YES || echo no)"
ask_yn "Продолжить установку?" Y || { warn "Отмена пользователем"; exit 0; }

# ── Настройка TG-уведомлений (после wizard'а, до начала установки) ──────────
setup_tg_notifications

# Старт-сообщение в TG
SERVER_PUBLIC_IP=$(curl -s4 -m 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
tg_notify "🟢 deploy.sh started
Host: $(hostname)
IP: ${SERVER_PUBLIC_IP}
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"



# ═════════════════════════════════════════════════════════════════════════════
# ШАГ 1: Базовые пакеты
# ═════════════════════════════════════════════════════════════════════════════
if [ "$INSTALL_BASE" = "1" ]; then
    step "Установка базовых пакетов"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        curl wget git ca-certificates gnupg2 lsb-release \
        ufw build-essential libssl-dev socat cron \
        software-properties-common apt-transport-https \
        net-tools dnsutils jq unzip
    log "Базовые пакеты установлены"
fi

# ═════════════════════════════════════════════════════════════════════════════
# ШАГ 2: sysctl-hardening
# ═════════════════════════════════════════════════════════════════════════════
if [ "$INSTALL_SYSCTL" = "1" ]; then
    step "Применение sysctl-hardening"
    cp -v "$REPO_ROOT/security/99-appaz-hardening.conf" /etc/sysctl.d/99-appaz-hardening.conf
    sysctl -p /etc/sysctl.d/99-appaz-hardening.conf >/dev/null
    log "sysctl-hardening применён. tcp_syncookies=$(sysctl -n net.ipv4.tcp_syncookies)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# ШАГ 3: ufw + правила
# ═════════════════════════════════════════════════════════════════════════════
if [ "$INSTALL_UFW" = "1" ]; then
    step "Настройка ufw"
    ufw --force reset >/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    ufw default deny routed
    ufw limit "$SSH_PORT"/tcp comment 'SSH with rate-limit'
    ufw allow 80/tcp   comment 'HTTP (LE challenge)'
    ufw allow 443/tcp  comment 'HTTPS'
    ufw allow 443/udp  comment 'Hysteria2 main'
    ufw allow 1443/udp comment 'Hysteria2 4G'
    ufw allow 8443/tcp comment 'VLESS Reality'
    ufw allow 2053/tcp comment 'VLESS gRPC'
    ufw allow 2083/tcp comment '3x-ui panel'
    ufw allow 2096/tcp comment '3x-ui subscription'
    if [ "$INSTALL_3PROXY" = "1" ] && [ -n "$PROXY_ALLOWED_IP" ] && [ "$PROXY_ALLOWED_IP" != "0.0.0.0/0" ]; then
        ufw allow from "$PROXY_ALLOWED_IP" to any port 8888 proto tcp comment '3proxy from whitelisted IP'
    fi
    ufw --force enable
    log "ufw активен"
    ufw status verbose | grep -E '^[0-9]|^\s+[0-9]|Status:' | head -20
fi

# ═════════════════════════════════════════════════════════════════════════════
# ШАГ 4: nginx + acme.sh + Let's Encrypt
# ═════════════════════════════════════════════════════════════════════════════
if [ "$INSTALL_NGINX" = "1" ]; then
    step "Установка nginx 1.30 из официального репозитория"
    curl -sS https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
        | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $OS_CODENAME nginx" \
        > /etc/apt/sources.list.d/nginx.list
    cat > /etc/apt/preferences.d/99nginx <<PIN
Package: *
Pin: origin nginx.org
Pin-Priority: 900
PIN
    apt-get update -qq
    apt-get install -y -qq nginx
    log "nginx $(nginx -v 2>&1 | awk -F/ '{print $2}')"

    step "Установка acme.sh и сертификата для $DOMAIN, *.$DOMAIN"
    if [ ! -d "/root/.acme.sh" ]; then
        curl -sS https://get.acme.sh | sh -s email="$EMAIL" >/dev/null
    fi
    export PATH="/root/.acme.sh:$PATH"
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null

    if [ "$SSL_METHOD" = "cf-dns" ]; then
        export CF_Token="$CF_TOKEN"
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" -d "*.$DOMAIN" --dns dns_cf --force
    else
        systemctl stop nginx 2>/dev/null || true
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" -d "www.$DOMAIN" --standalone --force
    fi

    mkdir -p /etc/ssl/private
    # reloadcmd выполняется acme.sh при КАЖДОМ автопродлении сертификата:
    #  • reload nginx — подхватить новый серт фронтом;
    #  • try-restart x-ui — если панель 3x-ui использует этот же серт напрямую
    #    (SSL-режим «Custom Certificate»), она читает файл только при старте,
    #    поэтому без рестарта отдавала бы просроченный серт после продления.
    #    try-restart трогает юнит только если он запущен; нет x-ui — no-op.
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file       /etc/ssl/private/private.key \
        --fullchain-file /etc/ssl/private/cert.crt \
        --reloadcmd      "systemctl reload nginx 2>/dev/null || true; systemctl try-restart x-ui 2>/dev/null || true"
    chmod 600 /etc/ssl/private/private.key
    log "Сертификат установлен в /etc/ssl/private/ (reloadcmd: nginx reload + x-ui restart)"

    step "Установка конфига nginx + сайта"
    # nginx из репозитория nginx.org не создаёт sites-available/sites-enabled
    # (это дебиановская конвенция) — создаём сами до копирования конфига.
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d
    cp -v "$REPO_ROOT/nginx/nginx.conf" /etc/nginx/nginx.conf
    cp -v "$REPO_ROOT/nginx/appaz.conf" /etc/nginx/sites-available/appaz
    ln -sf /etc/nginx/sites-available/appaz /etc/nginx/sites-enabled/appaz
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    mkdir -p /var/www/appaz
    cp -v "$REPO_ROOT/website/index.html" /var/www/appaz/index.html
    chown -R www-data:www-data /var/www/appaz 2>/dev/null || true

    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    log "nginx запущен. Test: curl -ksI https://$DOMAIN/ | head -3"
fi

# Предпочтительные настройки подписки 3x-ui (можно переопределить через env).
XUI_SUB_PATH="${XUI_SUB_PATH:-/siha-vpn-sub/}"
XUI_SUB_JSON_PATH="${XUI_SUB_JSON_PATH:-/siha-vpn-sub-json/}"
XUI_REMARK_TEMPLATE="${XUI_REMARK_TEMPLATE:-{{INBOUND}}|📊{{TRAFFIC_LEFT}}|⏳{{DAYS_LEFT}}D}"

# Применяет наши настройки подписки к БД панели 3x-ui.
# УСТОЙЧИВОСТЬ К БУДУЩИМ ВЕРСИЯМ: шаг сугубо best-effort — при любой смене
# схемы (переименование таблицы `settings`/ключей, другой тип БД) он тихо
# пропускается и НИКОГДА не роняет установку. Обновляются только уже
# существующие ключи (UPDATE ... WHERE key=...), новые не создаются.
apply_xui_sub_settings() {
    local dbtype
    dbtype=$(xui_result_get XUI_DB_TYPE 2>/dev/null)
    [ -z "$dbtype" ] && dbtype=$(grep -oP 'XUI_DB_TYPE=\K\S+' /etc/default/x-ui 2>/dev/null || echo sqlite)

    # db_exec <sql> — выполняет SQL, печатает результат; ошибки/несовместимость → пусто.
    local db_exec
    if [ "$dbtype" = "postgres" ]; then
        command -v psql >/dev/null 2>&1 || { warn "psql не найден — пропускаю донастройку подписки (настрой вручную в панели)"; return 0; }
        db_exec() { sudo -u postgres psql -d xui -tAc "$1" 2>/dev/null; }
    else
        local dbfile=/etc/x-ui/x-ui.db
        command -v sqlite3 >/dev/null 2>&1 || { warn "sqlite3 не найден — пропускаю донастройку подписки (настрой вручную в панели)"; return 0; }
        [ -f "$dbfile" ] || { warn "БД $dbfile не найдена — пропускаю донастройку подписки"; return 0; }
        db_exec() { sqlite3 "$dbfile" "$1" 2>/dev/null; }
    fi

    # Пробуем таблицу/ключ. Если схема изменилась в новой версии 3x-ui — тихо выходим.
    local probe
    probe=$(db_exec "SELECT count(*) FROM settings WHERE key='subEnable';" || true)
    if ! [[ "$probe" =~ ^[0-9]+$ ]]; then
        warn "Схема настроек 3x-ui не распознана (возможно, новая версия) — пропускаю донастройку подписки."
        warn "Настрой вручную в панели: Subscription → включить JSON, задать URI-пути и шаблон примечания."
        return 0
    fi

    # Обновляем только существующие ключи. Отсутствующий ключ = 0 строк, не ошибка.
    db_exec "UPDATE settings SET value='true'                 WHERE key='subEnable';"     >/dev/null || true
    db_exec "UPDATE settings SET value='true'                 WHERE key='subJsonEnable';" >/dev/null || true
    db_exec "UPDATE settings SET value='$XUI_SUB_PATH'        WHERE key='subPath';"       >/dev/null || true
    db_exec "UPDATE settings SET value='$XUI_SUB_JSON_PATH'   WHERE key='subJsonPath';"   >/dev/null || true
    db_exec "UPDATE settings SET value='$XUI_REMARK_TEMPLATE' WHERE key='remarkTemplate';" >/dev/null || true

    systemctl restart x-ui 2>/dev/null || true
    log "Настройки подписки 3x-ui применены (JSON on, subPath=$XUI_SUB_PATH, subJsonPath=$XUI_SUB_JSON_PATH, remarkTemplate обновлён)"
}

# ═════════════════════════════════════════════════════════════════════════════
# ШАГ 5: 3x-ui панель
# ═════════════════════════════════════════════════════════════════════════════
if [ "$INSTALL_XUI" = "1" ]; then
    step "Установка 3x-ui (официальный установщик)"
    if [ -d "/usr/local/x-ui" ]; then
        warn "3x-ui уже установлен в /usr/local/x-ui, пропускаем"
    else
        # Запускаем ОФИЦИАЛЬНЫЙ установщик ИНТЕРАКТИВНО — чтобы его родной вопрос
        # выбора БД (SQLite / PostgreSQL) видел ты и отвечал сам.
        # Почему не через env XUI_DB_TYPE=postgres: в неинтерактивном режиме эта
        # переменная наследуется бинарником x-ui, которого установщик вызывает для
        # чтения настроек ещё ДО создания DSN → "Database initialization failed".
        # В интерактиве БД ставится в правильном порядке, проблемы нет.
        echo
        warn "Сейчас запустится интерактивный установщик 3x-ui. Ответь на его вопросы:"
        warn "  • Database Selection: для большого числа клиентов (тысячи) выбирай 2) PostgreSQL,"
        warn "    для небольшого — 1) SQLite. PostgreSQL: далее выбери 1) Install locally."
        warn "  • Panel Port: можно оставить случайный (Enter) или задать свой."
        warn "  • SSL Certificate Setup: выбирай 4) Skip SSL — TLS у нас терминирует nginx"
        warn "    (панель за реверс-прокси). Опции 1-3 тут не нужны."
        echo
        if [ -e /dev/tty ]; then
            bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) </dev/tty
        else
            # Нет терминала (--auto / CI): установщик уйдёт в NONINTERACTIVE и поставит
            # SQLite. Для PostgreSQL в этом режиме задай XUI_DB_TYPE=postgres и XUI_DB_DSN
            # заранее (см. docs), иначе панель ставится на SQLite по умолчанию.
            warn "Нет /dev/tty — установщик 3x-ui пойдёт неинтерактивно (по умолчанию SQLite)."
            bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< $'\n\n\n\n\n\n'
        fi
        log "3x-ui установлен. Доступ: x-ui (CLI) или https://SERVER:RANDOM_PORT/PATH"
        warn "ВНИМАНИЕ: запиши логин/пароль/порт/путь из вывода установщика выше!"
    fi
    systemctl enable x-ui 2>/dev/null || true
    systemctl status x-ui --no-pager | head -5 || true

    # Донастройка подписки (best-effort; не роняет установку при смене схемы БД).
    apply_xui_sub_settings || true
fi

# ═════════════════════════════════════════════════════════════════════════════
# ШАГ 6: 3proxy (сборка из исходников + конфиг + systemd)
# ═════════════════════════════════════════════════════════════════════════════
if [ "$INSTALL_3PROXY" = "1" ]; then
    step "Сборка 3proxy из исходников"
    if [ -x "/usr/local/bin/3proxy" ]; then
        warn "3proxy уже собран в /usr/local/bin/3proxy"
    else
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        git clone -q https://github.com/3proxy/3proxy.git
        cd 3proxy
        ln -sf Makefile.Linux Makefile
        make -j$(nproc) >/dev/null 2>&1
        if [ ! -f bin/3proxy ]; then err "Сборка 3proxy упала"; exit 1; fi
        cp bin/3proxy /usr/local/bin/3proxy
        chmod +x /usr/local/bin/3proxy
        cd /
        rm -rf "$TMP_DIR"
        log "3proxy скомпилирован → /usr/local/bin/3proxy"
    fi

    step "Конфиг 3proxy"
    id proxy >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /var/lib/3proxy proxy
    mkdir -p /etc/3proxy /var/log/3proxy /var/lib/3proxy
    chown proxy:proxy /var/log/3proxy /var/lib/3proxy

    sed -e "s|PROXY_USER|$PROXY_USER|g" \
        -e "s|PROXY_PASSWORD|$PROXY_PASS|g" \
        -e "s|ALLOWED_IP|$PROXY_ALLOWED_IP|g" \
        "$REPO_ROOT/proxy/3proxy.cfg.template" > /etc/3proxy/3proxy.cfg
    chmod 600 /etc/3proxy/3proxy.cfg
    chown root:proxy /etc/3proxy/3proxy.cfg
    log "Конфиг создан: /etc/3proxy/3proxy.cfg (логин $PROXY_USER, whitelist $PROXY_ALLOWED_IP)"

    step "systemd-unit для 3proxy"
    cp -v "$REPO_ROOT/proxy/3proxy.service" /etc/systemd/system/3proxy.service
    systemctl daemon-reload
    systemctl enable 3proxy
    systemctl restart 3proxy
    sleep 2
    if systemctl is-active --quiet 3proxy; then
        log "3proxy запущен на 8888/tcp. URL: http://$PROXY_USER:***@$(curl -s4 ifconfig.me):8888"
    else
        err "3proxy не запустился. journalctl -u 3proxy"
        journalctl -u 3proxy -n 20 --no-pager
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# ШАГ 7: fail2ban + наши nginx-фильтры
# ═════════════════════════════════════════════════════════════════════════════
if [ "$INSTALL_FAIL2BAN" = "1" ]; then
    step "Установка fail2ban + nginx-фильтров"
    apt-get install -y -qq fail2ban

    cp -v "$REPO_ROOT/security/fail2ban-jail.local"      /etc/fail2ban/jail.local
    cp -v "$REPO_ROOT/security/nginx-badbots.conf"       /etc/fail2ban/filter.d/nginx-badbots.conf
    cp -v "$REPO_ROOT/security/nginx-tlsjunk.conf"       /etc/fail2ban/filter.d/nginx-tlsjunk.conf
    cp -v "$REPO_ROOT/security/nginx-authabuse.conf"     /etc/fail2ban/filter.d/nginx-authabuse.conf

    systemctl enable fail2ban
    systemctl restart fail2ban
    sleep 2
    fail2ban-client status 2>/dev/null || warn "fail2ban-client недоступен, проверь руками"
    log "fail2ban активен с 4 jail'ами"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Финальный summary
# ═════════════════════════════════════════════════════════════════════════════
step "Установка завершена"

cat <<SUMMARY

╔══════════════════════════════════════════════════════════════════════╗
║  Что установлено и работает                                          ║
╠══════════════════════════════════════════════════════════════════════╣
$([ "$INSTALL_BASE" = "1" ]     && echo "║  ✓ Базовые пакеты                                                    ║")
$([ "$INSTALL_SYSCTL" = "1" ]   && echo "║  ✓ sysctl-hardening активен                                          ║")
$([ "$INSTALL_UFW" = "1" ]      && echo "║  ✓ ufw настроен и активен                                            ║")
$([ "$INSTALL_NGINX" = "1" ]    && echo "║  ✓ nginx + сертификат для $DOMAIN                                    ║")
$([ "$INSTALL_XUI" = "1" ]      && echo "║  ✓ 3x-ui панель                                                       ║")
$([ "$INSTALL_3PROXY" = "1" ]   && echo "║  ✓ 3proxy на 8888/tcp                                                ║")
$([ "$INSTALL_FAIL2BAN" = "1" ] && echo "║  ✓ fail2ban + 4 jail                                                  ║")
╚══════════════════════════════════════════════════════════════════════╝

Что нужно сделать руками после установки:

1. Если ставили 3x-ui — открой панель и создай инбаунды:
   • NL WS:        port=10000  listen=127.0.0.1  protocol=vless  network=ws  path=/api/render/stream
   • NL WS 2:      port=10005  listen=127.0.0.1  protocol=vless  network=ws  path=/ws-vpn-2
   • NL HYSTERIA:  port=443    protocol=hysteria2 (UDP, основной)
   • NL HYSTERIA 4G: port=1443 protocol=hysteria2 (UDP, бэкап)
   • NL VLESS Reality: port=8443  protocol=vless  security=reality  donor=www.sony.com
   • NL GRPC:      port=2053  protocol=vless  network=grpc

2. Закрой SSH-вход по паролю:
   • Скопируй свой публичный SSH-ключ в /root/.ssh/authorized_keys
   • В /etc/ssh/sshd_config: PasswordAuthentication no
   • systemctl restart ssh

3. Проверь работу:
   • curl -ksI https://$DOMAIN/         # должен быть HTTP/2 200
   • systemctl status nginx fail2ban 3proxy x-ui
   • ss -tlnp ; ss -ulnp

4. Подробнее в docs/01-quickstart.md

SUMMARY

# ── Финальные действия: JSON-отчёт + время + TG ────────────────────────────
SCRIPT_END_TS=$(date +%s)
ELAPSED=$((SCRIPT_END_TS - SCRIPT_START_TS))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

if [ "$INSTALL_XUI" = "1" ] && [ -n "${TG_BOT_TOKEN:-}" ]; then
    log "Шлю отчёт для мастер-сервера в Telegram"
    report_panel_to_tg_interactive "${DOMAIN:-appaz.xyz}" || warn "Не удалось отправить отчёт в TG"
fi

tg_notify "✅ deploy.sh finished
Host: $(hostname)
Duration: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"

log "Готово за ${ELAPSED_MIN}m ${ELAPSED_SEC}s. Удачи."
