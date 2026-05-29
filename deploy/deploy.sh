#!/usr/bin/env bash
# Разворачивает заглушку appaz + nginx + сертификат на новом Ubuntu 22/24
# Запускать от root. Перед запуском задать переменные окружения:
#   DOMAIN=appaz.xyz
#   CF_TOKEN=<токен Cloudflare с правами DNS:Edit + Zone:Read>
#   EMAIL=<твоя почта для LE>

set -euo pipefail
: "${DOMAIN:?задай DOMAIN=appaz.xyz}"
: "${CF_TOKEN:?задай CF_TOKEN=...}"
: "${EMAIL:?задай EMAIL=...}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[1/6] Пакеты"
apt update
apt install -y nginx libnginx-mod-stream sqlite3 curl socat tcpdump ufw

echo "[2/6] Файрвол"
SSH_PORT="${SSH_PORT:-22}"
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 38291/tcp comment '3x-ui panel'
ufw allow 38294/tcp comment '3x-ui sub'
ufw --force enable

echo "[3/6] acme.sh + Let's Encrypt wildcard через Cloudflare"
curl -s https://get.acme.sh | sh -s email="${EMAIL}"
export CF_Token="${CF_TOKEN}"
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue --dns dns_cf \
  -d "${DOMAIN}" -d "*.${DOMAIN}" --keylength ec-256

mkdir -p /etc/ssl/appaz
chmod 700 /etc/ssl/appaz
~/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" --ecc \
  --fullchain-file /etc/ssl/appaz/fullchain.pem \
  --key-file /etc/ssl/appaz/privkey.pem \
  --reloadcmd "systemctl reload nginx"
chmod 600 /etc/ssl/appaz/privkey.pem

echo "[4/6] Заглушка"
mkdir -p /var/www/appaz
cp "${REPO_DIR}/website/index.html" /var/www/appaz/
chown -R www-data:www-data /var/www/appaz

echo "[5/6] Nginx"
rm -f /etc/nginx/sites-enabled/default
cp "${REPO_DIR}/nginx/appaz.conf" /etc/nginx/sites-available/appaz
ln -sf /etc/nginx/sites-available/appaz /etc/nginx/sites-enabled/appaz
nginx -t
systemctl reload nginx

echo "[6/6] 3x-ui (последняя версия — НЕ v3.2.0, в ней баг SNI!)"
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

echo "Готово. Дальше — настрой Reality в панели руками. См. notes/reality-setup.md"
