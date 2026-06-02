# Recovery — что делать если что-то упало

Сценарии когда сервис не отвечает или сервер «всё, кранты».

## Сайт не открывается (HTTPS 502/504/timeout)

```bash
# 1. nginx живой?
systemctl status nginx --no-pager | head -10

# 2. Слушает 443?
ss -tlnp | grep :443

# 3. Конфиг валидный?
nginx -t

# 4. Логи
tail -50 /var/log/nginx/error.log
journalctl -u nginx -n 30 --no-pager
```

**Типичные причины**:
- Сертификат истёк → `/root/.acme.sh/acme.sh --renew -d appaz.xyz --force`
- Кто-то правил конфиг и сломал синтаксис → откатиться на бэкап `/etc/nginx/sites-available/appaz.bak.*`
- Закончилось место на диске → `df -h` ; `journalctl --vacuum-time=2d`

## VPN не подключается с клиента

```bash
# 1. Xray поднял все инбаунды?
ss -tlnp | grep xray
ss -ulnp | grep xray

# Должно быть видно (минимум):
# 127.0.0.1:10000  (NL WS)
# 127.0.0.1:10005  (NL WS 2)
# *:4443           (VLESS Reality)
# *:2053           (NL GRPC)
# *:443/udp        (Hysteria main)
# *:1443/udp       (Hysteria 4G)

# 2. 3x-ui сервис активен?
systemctl status x-ui --no-pager | head -10

# 3. WS-канал через nginx отвечает?
curl -ks -i \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://www.appaz.xyz/api/render/stream | head -3
# Ожидаем: HTTP/2 400 (это норма — Xray отказал т.к. VLESS-handshake не пришёл)
# Если 502 — Xray не слушает, рестартни x-ui

# 4. БД 3x-ui цела?
sudo -u postgres psql -d xui -c "SELECT id, remark, port, listen, protocol FROM inbounds;"

# 5. Логи Xray
tail -50 /usr/local/x-ui/bin/access.log
tail -50 /usr/local/x-ui/bin/error.log
```

**Если ничего не помогает**: `systemctl restart x-ui` + перезагрузить страницу панели в браузере.

## fail2ban забанил мой IP

**С консоли хостера** (web-консоль, KVM):
```bash
fail2ban-client unban <ТВОЙ_IP>

# Узнать кто забанен в каком jail
fail2ban-client status sshd
fail2ban-client status nginx-badbots
```

**Если совсем не пускает** — отключи fail2ban временно через rescue mode:
```bash
systemctl stop fail2ban
iptables -F
# поправь /etc/fail2ban/jail.local, добавь ignoreip
systemctl start fail2ban
```

## 3proxy не работает (Telegram-бот не подключается)

```bash
# Статус
systemctl status 3proxy --no-pager | head -10
journalctl -u 3proxy -n 30 --no-pager

# Слушает 8888?
ss -tlnp | grep 8888

# Тест с whitelisted IP (с TG-сервера РФ)
curl -x 'http://USER:PASS@SERVER:8888' https://api.ipify.org
# Должно вернуть IP сервера в Амстердаме (не клиента)

# ufw разрешает с этого IP?
ufw status verbose | grep 8888
```

## Сервер полностью не отвечает (SSH тоже)

1. **Зайди через консоль хостера** (web KVM, обычно есть у любого VPS)
2. Посмотри логи: `journalctl -xe`, `dmesg | tail -50`
3. Проверь диск: `df -h` (часто причина — забит диск)
4. Проверь нагрузку: `top`, `iotop`

**Если диск забит**:
```bash
# Очистка журналов
journalctl --vacuum-time=2d
# Очистка apt-кеша
apt clean
# Очистка старых логов
find /var/log -name "*.gz" -mtime +7 -delete
find /var/log -name "*.log.*" -mtime +7 -delete
# Очистка docker если есть
docker system prune -af 2>/dev/null || true
```

## Сертификат Let's Encrypt истёк

```bash
# Принудительное обновление через CF DNS-01
export CF_Token="ваш_токен"
/root/.acme.sh/acme.sh --renew -d appaz.xyz --force

# Проверка cron-задачи на автообновление
crontab -l | grep acme
# Должна быть строка типа: 0 0 * * * /root/.acme.sh/acme.sh --cron

# Если cron-job нет — добавить
/root/.acme.sh/acme.sh --install-cronjob
```

## Хостер забанил мой VPS / РКН залочил IP

Симптом: VPN работает только с зарубежных сетей, из РФ всё отваливается.

**Лечение**: переезд на новый сервер.
1. Создай новый VPS у другого хостера (или хотя бы в другой подсети)
2. Клонируй репо: `git clone https://github.com/MuhammadAmadi/appaz-vpn /opt/appaz-vpn`
3. Запусти `bash /opt/appaz-vpn/deploy/deploy.sh`
4. Поменяй A-записи в Cloudflare на новый IP
5. Раздай новые подписки клиентам

## Полный rebuild с нуля

Если совсем всё плохо и хочется начать заново:
```bash
# С чистого Ubuntu 22.04
apt update && apt install -y git
git clone https://github.com/MuhammadAmadi/appaz-vpn.git /opt/appaz-vpn
cd /opt/appaz-vpn
bash deploy/deploy.sh
```

Скрипт всё поставит и настроит сам. Останется создать инбаунды в 3x-ui (см. docs/01-quickstart.md).
