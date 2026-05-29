# appaz-vpn

VPN-стек VLESS+Reality (3x-ui) на Ubuntu 22/24 за nginx-заглушкой `appaz`.

## Архитектура

- Xray Reality слушает `0.0.0.0:443` напрямую
- Reality fallback идёт на `127.0.0.1:8443`
- nginx HTTP-блок на `127.0.0.1:8443` отдаёт `website/index.html` + фейковый `/api/auth/login` (401)
- Сертификат wildcard `*.appaz.xyz` от Let's Encrypt через Cloudflare DNS-01
- Файрвол ufw: открыты только 22, 80, 443/tcp, 443/udp, 38291, 38294

## Развёртывание на новом сервере

1. Купи VPS Ubuntu 22 или 24, направь домен серой тучкой на его IP
2. Зайди по SSH, поставь git и склонируй репо:
   `apt install -y git && git clone https://github.com/USER/appaz-vpn.git /opt/appaz-vpn`
3. Запусти деплой:
   `export DOMAIN=appaz.xyz CF_TOKEN=токен EMAIL=почта && /opt/appaz-vpn/deploy/deploy.sh`
4. Зайди в 3x-ui (`https://новый-IP:38291`) и настрой Reality по `notes/reality-setup.md`

## Важно

- 3x-ui v3.2.0 содержит баг: кнопка обновления SNI вставляет markdown вместо имени.
  Ставь свежую версию или не нажимай эту кнопку.
- Если SNI засрался — чинить через SQLite, см. `notes/reality-setup.md`
