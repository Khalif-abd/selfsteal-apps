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

## Приложения

Приложение ставится на домен: nginx проксирует его по TLS, сам сервис слушает только `127.0.0.1`.
Меню → «Приложения», или:

```bash
sudo selfsteal-apps app list
```

### Jitsi Meet

```bash
sudo selfsteal-apps app jitsi install --domain meet.example.com          # по умолчанию --auth
sudo selfsteal-apps app jitsi user add admin                             # пароль сгенерируется
sudo selfsteal-apps app jitsi user list | passwd <имя> | del <имя>
sudo selfsteal-apps app jitsi status | logs [web|prosody|jicofo|jvb] | restart
sudo selfsteal-apps app jitsi update            # на новейший stable-* релиз docker-jitsi-meet
sudo selfsteal-apps app jitsi uninstall         # домен вернётся к заглушке 403
```

- Сайт открывается всем, а **комнаты создают только пользователи** (`AUTH_TYPE=internal`), гости входят по ссылке.
  `--no-auth` — открытый режим.
- Релиз — последний тег `stable-*` [docker-jitsi-meet](https://github.com/jitsi/docker-jitsi-meet); compose и образы
  берутся из одного тега. Секреты генерируются один раз и не меняются при обновлениях.
- Web — `127.0.0.1:8000` (`--http-port`), медиа — **UDP/10000** (`--jvb-port`), его нужно открыть в firewall
  (ufw скрипт предложит открыть сам; внешний firewall хостера — вручную).
- IPv4-only (`ENABLE_IPV6=0`) — работает на хостах с выключенным IPv6. Нужно ~2 ГБ RAM и Docker Compose 2.24.4+.
- Данные: `/opt/selfsteal-apps/apps/jitsi/` (`src/` — checkout, `config/` — конфиг и учётки).

**Перенос с selfsteal-jitsi** — автоматически при `app jitsi install` (или сразу после `adopt`):
переносятся `.env` (секреты), учётки Prosody, домен и порты; старый стек `/opt/jitsi` останавливается
прямо перед стартом нового, его файлы остаются.

## Перенос с nginx-selfsteal (DigneZzZ) / selfsteal-jitsi

```bash
sudo selfsteal-apps adopt
```

- читает домен, сокет/порт, `proxy_protocol` и сертификат из `/opt/nginx-selfsteal/conf.d/selfsteal.conf`;
- если стоит `selfsteal-jitsi` — домен сразу проксируется на Jitsi, затем скрипт предлагает перенести Jitsi в модуль `app jitsi`;
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

Два способа получить сертификат, плюс перенос готового:

| | Отдельный на домен | Wildcard через Cloudflare |
|---|---|---|
| Команда | `cert issue meet.example.com` | `cert wildcard example.com` (можно указать и поддомен — зона определится сама) |
| Покрывает | один хост | `*.example.com` + `example.com` (поддомены 1-го уровня) |
| Проверка | http-01, **нужен открытый TCP/80** | dns-01 через API Cloudflare, порт 80 не нужен |
| CT-логи (crt.sh) | виден каждый поддомен | виден только `*.example.com` |
| Продление | автоматически (acme.sh, cron) | автоматически, тоже через Cloudflare |

- **Домен сам находит wildcard.** При `domain add` если в хранилище есть wildcard его зоны — он используется,
  ничего не выпускается. Если нет — в меню выбор: отдельный / wildcard / импорт / без сертификата.
  Без меню: при сохранённом токене зоны — wildcard, иначе http-01 (`--http`, `--wildcard`, `--no-cert` — явно).
- **Токен Cloudflare:** My Profile → API Tokens → Create Token → шаблон «Edit zone DNS», Zone Resources —
  только нужная зона, желательно Client IP Filtering по IP нод. Плюс **Zone ID** (зона → Overview, справа внизу).
  Хранится в `/etc/selfsteal-apps/cloudflare/<зона>.env` (600), у каждой зоны свой.
- Let's Encrypt выдаёт один и тот же набор имён не больше **5 раз в неделю** — не выпускайте один wildcard
  на многих нодах, выпустите на одной и перенесите.

### Перенос на другую ноду (вручную)

```bash
# на ноде, где сертификат выпущен
sudo selfsteal-apps cert export example.com          # -> /root/selfsteal-cert-star.example.com-<дата>.tar.gz
scp /root/selfsteal-cert-star.example.com-*.tar.gz root@node2:/root/

# на другой ноде
sudo selfsteal-apps cert import /root/selfsteal-cert-star.example.com-<дата>.tar.gz
```

`import` принимает архив, папку или пару `fullchain.pem privkey.pem`; сам читает имена из сертификата
(wildcard или нет), проверяет, что ключ подходит, и подключает все домены зоны.
Можно и совсем руками: скопировать папку `/opt/selfsteal-apps/nginx/ssl/star.example.com/` в тот же путь и
выполнить `selfsteal-apps restart`.

На ноде-получателе сертификат **не продлевается** (`cert list` покажет «без автопродления» и подсветит,
когда до конца < 14 дней) — после продления на исходной ноде повторите экспорт/импорт.

## Где что лежит

| Путь | Что |
|---|---|
| `/usr/local/lib/selfsteal-apps/` | код (обновляется `update`) |
| `/usr/local/bin/selfsteal-apps` | команда (симлинк) |
| `/etc/selfsteal-apps/config.env` | настройки (режим, порты, email) |
| `/etc/selfsteal-apps/domains/*.env` | по файлу на домен |
| `/etc/selfsteal-apps/acme/` | acme.sh и его данные |
| `/opt/selfsteal-apps/apps/<имя>/` | данные приложений |
| `/opt/selfsteal-apps/nginx/` | docker-compose, nginx.conf, `conf.d/sites/<домен>.conf` |
| `/opt/selfsteal-apps/nginx/ssl/` | сертификаты: `<домен>/` и `star.<зона>/` (wildcard) |
| `/etc/selfsteal-apps/cloudflare/` | токены Cloudflare по зонам |
| `/var/log/selfsteal-apps.log` | журнал действий скрипта |

Логи nginx — в `docker logs selfsteal-nginx` (с ротацией 3×10 МБ), реальный IP клиента берётся из proxy_protocol.

## Требования

Debian/Ubuntu (или другой Linux с systemd/cron), root, Docker + Compose v2 (предложит поставить), curl, openssl, git.

## Планы

Nextcloud, Matrix + Element как модули `apps/<name>/`, центральная раздача сертификатов на ноды,
relay-режим (свой 443, маршрутизация по SNI / секретным путям на зарубежную ноду).

## Лицензия

MIT. Определение `/dev/shm` у контейнеров Xray и общая схема nginx-selfsteal основаны на
[DigneZzZ/remnawave-scripts](https://github.com/DigneZzZ/remnawave-scripts) (MIT).
