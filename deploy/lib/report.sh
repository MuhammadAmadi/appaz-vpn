#!/bin/bash
# ============================================================================
# report.sh — генерирует финальный JSON-отчёт для мастера
# ============================================================================

# Достаёт API-токен или создаёт новый master-integration
get_or_create_api_token() {
    local token_name="master-integration"
    local existing
    existing=$(sudo -u postgres psql -d xui -At -c "SELECT token FROM api_tokens WHERE name = '$token_name';" 2>/dev/null)
    if [ -n "$existing" ]; then
        echo "$existing"
        return 0
    fi
    local new_token
    new_token=$(openssl rand -base64 36 | tr -d '/+=\n' | head -c 48)
    local now_ms=$(( $(date +%s) * 1000 ))
    sudo -u postgres psql -d xui -c \
      "INSERT INTO api_tokens (name, token, enabled, created_at) VALUES ('$token_name', '$new_token', true, $now_ms);" \
      >/dev/null 2>&1
    echo "$new_token"
}

# Достаёт значение из таблицы settings
get_setting() {
    local key="$1"
    sudo -u postgres psql -d xui -At -c "SELECT value FROM settings WHERE key = '$key';" 2>/dev/null
}

# Достаёт username администратора панели (пароль в БД — bcrypt, нечитаем)
get_panel_username() {
    sudo -u postgres psql -d xui -At -c "SELECT username FROM users ORDER BY id LIMIT 1;" 2>/dev/null
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
    ipv6=$(curl -s6 -m 5 ifconfig.me 2>/dev/null || echo "")
    [[ "$ipv6" =~ ^[0-9a-fA-F:]+$ ]] || ipv6=""

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
