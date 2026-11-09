# selfsteal-apps

nginx-маскировка для **Xray Reality (selfsteal)**: на одном сервере с Xray поднимается nginx с настоящими
сертификатами Let's Encrypt, а всё, что не является VPN-трафиком, получает обычный сайт.
Поддерживается **несколько доменов** — поддомены одной зоны и совершенно разные домены равноправны.

Замена связки `selfsteal.sh` (DigneZzZ) + `selfsteal-jitsi`: свой nginx, свой acme.sh, ничего чужого не патчим.

```
TCP/443 → Xray Reality ─┬─ VPN-клиент → VPN
                        └─ всё остальное → unix:/dev/shm/nginx.sock (xver 1 / proxy_protocol)
                                            → nginx: TLS по SNI → заглушка / прокси на сервис
TCP/80  → nginx: ACME http-01 + редирект на https
```

Неизвестный SNI на TLS-слушателе → handshake отклоняется (`ssl_reject_handshake`), как у многих реальных серверов.

## Установка

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Khalif-abd/selfsteal-apps/main/install.sh)
```

Ставит команду `selfsteal-apps` и открывает интерактивное меню. Дальше просто:

```bash
sudo selfsteal-apps
```

(без `sudo` команда сама перезапустится через sudo).

## Без меню

```bash
# установка: сокет (по умолчанию) или TCP; публичный порт Reality — для редиректов http→https
sudo selfsteal-apps install --socket --public-port 443 --email you@example.com --yes
sudo selfsteal-apps install --tcp --tcp-port 9443 --public-port 8443 --yes

# домены
sudo selfsteal-apps domain add meet.example.com --proxy http://127.0.0.1:8000   # прокси на локальный сервис
sudo selfsteal-apps domain add cloud.other.net --page 403                       # заглушка nginx
sudo selfsteal-apps domain set cloud.other.net --page welcome
sudo selfsteal-apps domain list
sudo selfsteal-apps domain remove cloud.other.net

# сертификаты
sudo selfsteal-apps cert status
sudo selfsteal-apps cert reissue meet.example.com      # принудительный перевыпуск
sudo selfsteal-apps cert renew                         # продлить, у кого подходит срок
sudo selfsteal-apps cert manual meet.example.com fullchain.pem privkey.pem   # свой/wildcard

# сервис
sudo selfsteal-apps status | logs | restart | down | xray | update | uninstall [--purge]
```

Заглушки: `403`, `404`, `502`, `503` (стандартные страницы ошибок nginx, без версии) и `welcome` («Welcome to nginx!»).

## Перенос с nginx-selfsteal (DigneZzZ) / selfsteal-jitsi

```bash
sudo selfsteal-apps adopt
```

- читает домен, сокет/порт, `proxy_protocol` и сертификат из `/opt/nginx-selfsteal/conf.d/selfsteal.conf`;
- если стоит `selfsteal-jitsi` — домен проксируется на Jitsi (`127.0.0.1:8000`), Jitsi не трогается;
- останавливает контейнер `nginx-selfsteal` (файлы остаются), запускает свой на том же сокете — Xray/remnanode менять не нужно;
- отключает в cron старое задание `acme-renew.sh` (оно ставит iptables-редирект 443 на время продления);
- перевыпускает сертификат своим acme.sh; если не вышло — продолжает работать старый.

Откат: `sudo selfsteal-apps down && (cd /opt/nginx-selfsteal && docker compose up -d)`.

## Настройка Xray (Remnawave → Config Profiles)

`sudo selfsteal-apps xray` печатает готовый блок:

```json
"realitySettings": {
  "xver": 1,
  "target": "/dev/shm/nginx.sock",
  "serverNames": ["meet.example.com", "cloud.other.net"]
}
```

- Каждый добавленный домен нужно внести в `serverNames` — **панель скрипт не трогает**.
- В сокет-режиме контейнер remnanode должен монтировать `/dev/shm:/dev/shm` — скрипт проверяет и предлагает добавить.
- `target` для TCP-режима — `127.0.0.1:<tcp-port>`.

## Сертификаты

- Let's Encrypt, http-01 через webroot нашего nginx на :80 — без iptables и временных портов. **TCP/80 должен быть открыт снаружи.**
- ECDSA P-256, срок 90 дней, acme.sh продлевает сам (cron) и делает `nginx -s reload`.
- Перед выпуском: проверка A-записи (= IP сервера) и локальная проверка challenge-пути.
- acme.sh живёт отдельно (`/etc/selfsteal-apps/acme`) и не пересекается с `~/.acme.sh`.

## Где что лежит

| Путь | Что |
|---|---|
| `/usr/local/lib/selfsteal-apps/` | код (обновляется `update`) |
| `/usr/local/bin/selfsteal-apps` | команда (симлинк) |
| `/etc/selfsteal-apps/config.env` | настройки (режим, порты, email) |
| `/etc/selfsteal-apps/domains/*.env` | по файлу на домен |
| `/etc/selfsteal-apps/acme/` | acme.sh и его данные |
| `/opt/selfsteal-apps/nginx/` | docker-compose, nginx.conf, `conf.d/sites/<домен>.conf`, `ssl/<домен>/` |
| `/var/log/selfsteal-apps.log` | журнал действий скрипта |

Логи nginx — в `docker logs selfsteal-nginx` (с ротацией 3×10 МБ), реальный IP клиента берётся из proxy_protocol.

## Требования

Debian/Ubuntu (или другой Linux с systemd/cron), root, Docker + Compose v2 (предложит поставить), curl, openssl, git.

## Планы

Приложения (Jitsi, Nextcloud, Matrix + Element) как модули `apps/<name>/`, wildcard через DNS-01,
relay-режим (свой 443, маршрутизация по SNI / секретным путям на зарубежную ноду).

## Лицензия

MIT. Определение `/dev/shm` у контейнеров Xray и общая схема nginx-selfsteal основаны на
[DigneZzZ/remnawave-scripts](https://github.com/DigneZzZ/remnawave-scripts) (MIT).
