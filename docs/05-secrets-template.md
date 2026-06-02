# Secrets template

**ВНИМАНИЕ**: этот файл — шаблон. Реальный файл `docs/05-secrets.md` (без `-template`) добавлен в `.gitignore` и не коммитится в репозиторий.

Сохрани заполненную копию в безопасном месте: менеджер паролей (1Password, Bitwarden, KeePass) или зашифрованный файл локально. **Никогда** не пуш в git, **никогда** не отправляй в чат.

## Как пользоваться

Скопируй этот файл:
```bash
cp docs/05-secrets-template.md docs/05-secrets.md
nano docs/05-secrets.md
```

Заполни своими значениями. Файл уже в `.gitignore` — случайно не закоммитится.

---

## Сервер
Hostname:     <SERVER_HOSTNAME>
IPv4:         <SERVER_IP>
SSH порт:     22
SSH пользователь: root
SSH пароль:   <PASSWORD>
SSH ключ:     ~/.ssh/id_ed25519 (если перешёл на ключи)
Хостер:       <PROVIDER>
Локация:      <REGION>
ОС:           Ubuntu 22.04

## Домен
Основной:     appaz.xyz
WWW:          www.appaz.xyz
API:          api.appaz.xyz (Cloudflare Worker)
Регистратор:  <REGISTRAR>
DNS:          Cloudflare
CF Account:   <CLOUDFLARE_EMAIL>
CF API Token: <CF_API_TOKEN>  (Zone:DNS:Edit для appaz.xyz)

## 3x-ui панель
URL:     https://<SERVER_IP>:<RANDOM_PORT>/<RANDOM_PATH>
Логин:   <USERNAME>
Пароль:  <PASSWORD>
2FA:     включена / выключена
API Token: <API_TOKEN>

## PostgreSQL (для 3x-ui)
Host:     127.0.0.1
Port:     5432
Database: xui
User:     <DB_USER>
Password: <DB_PASSWORD>

## 3proxy (Telegram-релей)
Сервер:   <SERVER_IP>:8888
Логин:    <PROXY_USER>
Пароль:   <PROXY_PASSWORD>
Whitelist: <ALLOWED_IP>  (IP того с кого разрешено подключаться)
URL для бота: http://<PROXY_USER>:<PROXY_PASSWORD>@<SERVER_IP>:8888

## Cloudflare Worker (форма Apply)
Worker name: <WORKER_NAME>
Route:       api.appaz.xyz/access
Email From:  support@appaz.xyz
Email To:    <YOUR_EMAIL>

## GitHub
Repo:     https://github.com/MuhammadAmadi/appaz-vpn
PAT:      <GITHUB_PERSONAL_ACCESS_TOKEN>  (scope: repo)

## Резервные копии

Где лежат бэкапы (БД 3x-ui, конфиги):
<BACKUP_LOCATION>
Последний бэкап: <DATE>

## История смены кредов
<YYYY-MM-DD>: <что поменял>
