# Интеграция VPN-сервера с мастером

Этот документ описывает как подключить новый VPN-сервер к мастер-серверу (центральная админка, биллинг, бот раздачи ключей).

## Архитектура
┌────────────────────────────────┐

│   Мастер-сервер (РФ)           │

│   ├─ БД пользователей          │

│   ├─ Биллинг                   │

│   ├─ Telegram-бот              │

│   └─ Admin-панель              │

└──────────────┬─────────────────┘

│ HTTPS, 3x-ui API

▼

┌────────────────────────────────┐  ┌────────────────────────────────┐

│   VPN-сервер 1 (NL VDSina)     │  │   VPN-сервер N (DE play2go)    │

│   ├─ nginx (сайт-заглушка)     │  │   ├─ nginx (сайт-заглушка)     │

│   ├─ Xray (VLESS WS, Reality)  │  │   ├─ Xray                      │

│   ├─ 3x-ui панель + API        │  │   ├─ 3x-ui панель + API        │

│   └─ subscription endpoint     │  │   └─ subscription endpoint     │

└────────────────────────────────┘  └────────────────────────────────┘

Мастер общается с VPN-серверами **только через 3x-ui API** (REST, HTTPS, авторизация через API-токен).

## Что мастер делает с VPN-сервером

| Действие | API-метод | URL-шаблон |
|---|---|---|
| Создать клиента | `POST` | `/panel/api/inbounds/addClient` |
| Удалить клиента | `POST` | `/panel/api/inbounds/{inboundId}/delClient/{uuid}` |
| Обновить лимит/expiry | `POST` | `/panel/api/inbounds/updateClient/{uuid}` |
| Получить subscription URL | вычисляется | `https://www.appaz.xyz:2096/sub/{sub_id}` |
| Список инбаундов | `GET` | `/panel/api/inbounds/list` |
| Статистика трафика | `GET` | `/panel/api/inbounds/getClientTraffics/{email}` |
| Сброс трафика | `POST` | `/panel/api/inbounds/{inboundId}/resetClientTraffic/{email}` |
| Ban / unban | `POST` | через `updateClient` с `enable: false/true` |

## Подключение нового VPN к мастеру

### 1. Установка сервера

Разверни сервер по `docs/01-quickstart.md`. Скрипт `deploy.sh` в конце пришлёт в Telegram **JSON-отчёт** с готовыми данными для мастера:

```json
{
  "name": "play2go-de-1",
  "ip": "1.2.3.4",
  "ipv6": "2a14:1e00:3:971::1",
  "domain": "appaz.xyz",
  "panel": {
    "url": "https://1.2.3.4:2083/random-path/",
    "user": "admin",
    "api_token": "PWCY...48-char-token..."
  },
  "subscription_port": 2096,
  ...
}
```

### 2. Добавление в админку мастера

Скопируй из JSON в форму добавления сервера на мастере:

- **Server name**: `play2go-de-1`
- **Panel URL**: `https://1.2.3.4:2083/random-path/`
- **API Token**: значение `api_token` (header `Authorization: Bearer ...`)
- **Subscription base URL**: `https://www.appaz.xyz:2096/sub/`

### 3. Проверка связи

Мастер должен сделать тестовый запрос:

```bash
curl -k -H "Authorization: Bearer ${API_TOKEN}" \
  "https://${PANEL_IP}:2083/${PANEL_PATH}/panel/api/inbounds/list"
```

Если возвращается JSON со списком инбаундов → связь работает.

## Структура inbounds на каждом VPN-сервере

Стандартный набор (по `docs/01-quickstart.md`):

| ID | Remark | Port | Listen | Protocol | Path |
|---|---|---|---|---|---|
| 2 | NL WS | 10000 | 127.0.0.1 | vless ws | /api/render/stream |
| 5 | NL HYSTERIA | 443 | — | hysteria2 | — |
| 6 | NL HYSTERIA 4G | 1443 | — | hysteria2 | — |
| 7 | NL VLESS | 8443 | — | vless reality | — |
| 8 | NL WS 2 | 10005 | 127.0.0.1 | vless ws | /ws-vpn-2 |
| 10 | NL GRPC | 2053 | 127.0.0.1 | vless grpc | /chri-grpc |

Когда мастер создаёт клиента, он добавляет его сразу во **все** активные инбаунды — пользователь получает подписку со всеми каналами.

## Идемпотентность API-токена

API-токен `master-integration` создаётся скриптом `deploy.sh` автоматически. При **повторном запуске** скрипт находит существующий токен и НЕ создаёт новый.

Если нужно **отозвать** токен (например, мастер скомпрометирован):

```bash
sudo -u postgres psql -d xui -c "DELETE FROM api_tokens WHERE name = 'master-integration';"
systemctl restart x-ui
# Следующий запуск deploy.sh создаст свежий токен
```

## Healthcheck с мастера

Мастер раз в N минут пингует:
- `https://www.appaz.xyz/` — должен вернуть **200**
- `https://${PANEL_IP}:2083/${PANEL_PATH}/panel/api/inbounds/list` — должен вернуть **200** с JSON

При **трёх подряд** ошибках сервер помечается красным в админке + уведомление в TG.

## Известные ограничения

- **API-токены НЕ ротируются автоматически** — поставь напоминание в календарь раз в год
- **Subscription endpoint порт 2096** должен быть открыт в ufw (сделано в `deploy.sh`)
- **CF серая тучка обязательна** — жёлтая режется РКН, и subscription URL ломается
