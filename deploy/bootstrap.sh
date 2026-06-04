#!/bin/bash
# ============================================================================
# appaz-vpn bootstrap.sh
# Скачивает deploy.sh, проверяет SHA256, запускает.
#
# Использование на чистом сервере:
#   curl -sSL https://raw.githubusercontent.com/MuhammadAmadi/appaz-vpn/main/deploy/bootstrap.sh | bash
# ============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $*"; }
err()  { echo -e "${RED}[bootstrap]${NC} $*" >&2; }

REPO_URL="https://github.com/MuhammadAmadi/appaz-vpn.git"
REPO_DIR="/opt/appaz-vpn"
RAW_BASE="https://raw.githubusercontent.com/MuhammadAmadi/appaz-vpn/main"

# Проверка root
if [ "$EUID" -ne 0 ]; then err "Запусти от root: sudo bash bootstrap.sh"; exit 1; fi

# Ставим минимальный набор для клонирования
log "Установка git и curl"
apt-get update -qq
apt-get install -y -qq git curl ca-certificates

# Клонируем репо (или обновляем если уже есть)
if [ -d "$REPO_DIR/.git" ]; then
    log "Репо уже есть, обновляю"
    cd "$REPO_DIR"
    git pull --quiet origin main
else
    log "Клонирую $REPO_URL в $REPO_DIR"
    git clone --quiet "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
fi

# Проверяем целостность deploy.sh
log "Проверка SHA256 хеша deploy.sh"
if [ ! -f "deploy/deploy.sh.sha256" ]; then
    err "Файл с эталонным хешем не найден"
    err "Кто-то мог подменить deploy.sh в репо. Прерываю."
    exit 1
fi

EXPECTED=$(cat deploy/deploy.sh.sha256 | tr -d '[:space:]')
ACTUAL=$(sha256sum deploy/deploy.sh | awk '{print $1}')

if [ "$EXPECTED" != "$ACTUAL" ]; then
    err "ХЕШИ НЕ СОВПАДАЮТ"
    err "Ожидался: $EXPECTED"
    err "Получен:  $ACTUAL"
    err "Это значит deploy.sh был изменён. Не запускаю."
    err "Если ты сам его правил — пересчитай хеш командой:"
    err "  sha256sum deploy/deploy.sh > deploy/deploy.sh.sha256"
    err "  git commit -am 'update deploy.sh hash' && git push"
    exit 1
fi
log "✓ Хеш совпадает: ${ACTUAL:0:16}..."

# Запускаем основной установщик
log "Запуск deploy.sh"
chmod +x deploy/deploy.sh
exec bash deploy/deploy.sh "$@"
