#!/bin/bash
# ============================================================================
# report.sh — генерирует финальный JSON-отчёт для мастера
# ============================================================================

# Файл, который официальный установщик 3x-ui пишет после установки (mode 600).
# Содержит XUI_USERNAME/XUI_PASSWORD/XUI_PANEL_PORT/XUI_WEB_BASE_PATH/
# XUI_API_TOKEN/XUI_ACCESS_URL/XUI_DB_TYPE. Работает независимо от типа БД
# (SQLite или PostgreSQL) — поэтому берём данные панели отсюда, а не из psql.
XUI_INSTALL_RESULT="/etc/x-ui/install-result.env"

# Достаёт одно значение из install-result.env, не засоряя глобальные переменные.
# Файл source-able (значения записаны через printf '%q'), читаем в subshell.
xui_result_get() {
    local key="$1"
    [ -f "$XUI_INSTALL_RESULT" ] || return 0
    ( set -a; . "$XUI_INSTALL_RESULT" >/dev/null 2>&1; printf '%s' "${!key}" )
}

# API-токен мастер-интеграции: установщик генерит его сам и кладёт в install-result.env.
get_or_create_api_token() {
    xui_result_get XUI_API_TOKEN
}

# webPort / webBasePath — из install-result.env (ключи XUI_PANEL_PORT / XUI_WEB_BASE_PATH).
get_setting() {
    local key="$1"
    case "$key" in
        webPort)     xui_result_get XUI_PANEL_PORT ;;
        webBasePath) xui_result_get XUI_WEB_BASE_PATH ;;
        *)           : ;;
    esac
}

# Username администратора панели.
get_panel_username() {
    xui_result_get XUI_USERNAME
}

# Сбрасывает пароль панели на свежий случайный, возвращает в чистом виде.
# Использует x-ui CLI команду setting -username -password.
reset_panel_password() {
    local username="$1"
    local new_pass
    # Генерим простой читаемый пароль 20 символов
    new_pass=$(openssl rand -base64 18 | tr -d '/+=\n' | head -c 20)
    # x-ui принимает новый пароль и хеширует сам
    /usr/local/x-ui/x-ui setting -username "$username" -password "$new_pass" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "ERROR_RESET_FAILED"
        return 1
    fi
    echo "$new_pass"
}

# Определяет глобальный IPv6-адрес сервера, перебирая несколько сервисов
# (один ifconfig.me иногда 403-ит определённые ASN/подсети хостеров —
# в этом случае тело ответа не должно попасть в отчёт как IP).
detect_ipv6() {
    local urls=(
        "https://api6.ipify.org"
        "https://ipv6.icanhazip.com"
        "https://v6.ident.me"
        "https://ifconfig.me"
    )
    local url out
    for url in "${urls[@]}"; do
        out=$(curl -s6 -m 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$out" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$out" == *:* ]]; then
            echo "$out"
            return 0
        fi
    done
    echo ""
}

# Собирает JSON для мастера.
# Аргументы:
#   $1 — domain
#   $2 — RESET_PANEL_PASS (если "1" — сбрасывает пароль, иначе нет)
build_report_json() {
    local domain="$1"
    local reset_pass="${2:-0}"

    local ip ipv6
    ip=$(curl -s4 -m 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip=""
    ipv6=$(detect_ipv6)

    local panel_port panel_path panel_user panel_pass_line
    panel_port=$(get_setting "webPort")
    panel_path=$(get_setting "webBasePath")
    panel_user=$(get_panel_username)
    panel_path="${panel_path#/}"
    panel_path="${panel_path%/}"

    # Пароль панели
    if [ "$reset_pass" = "1" ]; then
        local new_pass
        new_pass=$(reset_panel_password "$panel_user")
        panel_pass_line="\"pass\": \"${new_pass}\","
    else
        # Без сброса — пароль не показываем (в БД хеш, и так и так не получить)
        panel_pass_line="\"pass_note\": \"password unchanged, see your password manager\","
    fi

    local api_token
    api_token=$(get_or_create_api_token)

    local nginx_ver xray_ver
    nginx_ver=$(nginx -v 2>&1 | awk -F/ '{print $2}')
    xray_ver=$(/usr/local/x-ui/bin/xray-linux-amd64 -version 2>/dev/null | head -1 | awk '{print $2}')

    cat <<JSON
{
  "name": "$(hostname)",
  "ip": "${ip}",
  "ipv6": "${ipv6}",
  "domain": "${domain}",
  "panel": {
    "url": "https://${ip}:${panel_port}/${panel_path}/",
    "user": "${panel_user}",
    ${panel_pass_line}
    "api_token": "${api_token}"
  },
  "subscription_port": 2096,
  "versions": {
    "nginx": "${nginx_ver}",
    "xray": "${xray_ver}",
    "os": "$(lsb_release -ds 2>/dev/null | tr -d '\"')"
  },
  "installed_at": "$(date -Iseconds)"
}
JSON
}

# Шлёт JSON в TG. HTML-режим чтобы Telegram не делал авто-линки.
send_report_to_tg() {
    local domain="$1"
    local reset_pass="${2:-0}"
    local json
    json=$(build_report_json "$domain" "$reset_pass")
    local escaped
    escaped=$(echo "$json" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    local header="🚀 <b>Server ready for master integration</b>"
    [ "$reset_pass" = "1" ] && header="${header}
⚠️ <b>Panel password was RESET</b> — save the new one"
    local msg="${header}

<pre>${escaped}</pre>"
    _tg_send "$msg" "HTML"
}

# Интерактивно спрашивает «сбросить пароль панели?» и шлёт отчёт.
# Если RESET_PANEL_PASSWORD env-переменная установлена в "1" или "yes" — не спрашивает.
report_panel_to_tg_interactive() {
    local domain="$1"
    local reset="0"
    if [ -n "${RESET_PANEL_PASSWORD:-}" ]; then
        case "$RESET_PANEL_PASSWORD" in
            1|yes|true|Y|y) reset="1" ;;
        esac
    elif [ "${AUTO:-0}" = "1" ]; then
        reset="0"  # В авто-режиме по умолчанию не сбрасываем
    else
        read -p "Сбросить пароль панели 3x-ui и прислать новый в Telegram? [y/N] " ans
        [[ "$ans" =~ ^[Yy] ]] && reset="1"
    fi
    send_report_to_tg "$domain" "$reset"
    echo "Отчёт отправлен в Telegram (reset=$reset)"
}
