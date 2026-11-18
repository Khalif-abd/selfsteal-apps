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

Неизвестный SNI и заход по голому IP (`https://<IP>`) на TLS-слушателе → handshake отклоняется
(`ssl_reject_handshake`), как у многих реальных серверов. Это можно поменять — см. «Доступ по IP».

## Установка

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Khalif-abd/selfsteal-apps/main/install.sh)
```

Ставит команду `selfsteal-apps` и открывает интерактивное меню. Дальше просто:

```bash
sudo selfsteal-apps
```

(без `sudo` команда сама перезапустится через sudo).

Главный экран — сводка по ноде: версия nginx, режим доступа по IP, домены со сроком сертификатов
(сначала те, что требуют внимания; на экране первые 5, остальные — в разделе «Домены») и приложения с версиями.
Всё берётся с самой ноды, без запросов в интернет. Значки в меню выключаются в «Сервис» → «Выключить значки»
(или `SSA_NO_EMOJI=1`), если терминал рисует их криво.

## Без меню

```bash
# установка: сокет (по умолчанию) или TCP; публичный порт Reality — для редиректов http→https
sudo selfsteal-apps install --public-port 443 --email you@example.com --yes
sudo selfsteal-apps install --tcp --public-port 443 --yes   # только если Xray не видит /dev/shm (по умолчанию — сокеты)

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
sudo selfsteal-apps status | logs | down | xray | uninstall [--purge]
sudo selfsteal-apps apply           # пересобрать конфиг и перечитать его без перезапуска nginx
sudo selfsteal-apps restart         # то же, но с пересозданием контейнера
sudo selfsteal-apps update          # только скрипт (после него — apply, без перезапуска nginx)
sudo selfsteal-apps nginx version   # какая версия nginx запущена
sudo selfsteal-apps nginx update    # только nginx: скачать образ, проверить конфиг на нём, пересоздать
```

nginx берётся из образа `nginx:stable-alpine` (сборки nginx.org, исправления безопасности приходят туда быстрее,
чем в пакеты дистрибутивов). `restart` образ не скачивает — он вызывается при каждом изменении домена и должен
работать без Docker Hub. `update` обновляет только сам скрипт; свежий nginx ставится отдельно — `nginx update`.

### Несколько портов (несколько inbound в Xray)

Сайт — это **домен + публичный порт** (порт Xray inbound, на который приходит клиент). У каждого порта свой
слушатель nginx, поэтому один домен может отдавать разное на разных портах, а разные домены — жить на своих портах:

```bash
sudo selfsteal-apps domain add meet.example.com --port 444 --page 404        # тот же домен, другой порт
sudo selfsteal-apps app jitsi install --domain meet.example.com --port 444   # Jitsi на :444
sudo selfsteal-apps domain set meet.example.com --port 444 --page 502
sudo selfsteal-apps domain remove meet.example.com --port 444                # сертификат остаётся, пока есть другие порты
sudo selfsteal-apps domain move meet.example.com --to 8443                  # перенести на другой порт (меню: «Сменить порт»)
sudo selfsteal-apps app jitsi port 444                                       # приложение — на другой порт без переустановки
sudo selfsteal-apps xray                                                     # target и serverNames для каждого inbound
```

| Публичный порт | Xray `target` (сокеты) | Xray `target` (tcp) |
|---|---|---|
| основной (`--public-port`, обычно 443) | `/dev/shm/nginx.sock` | `127.0.0.1:9443` |
| любой другой, например 444 | `/dev/shm/nginx-444.sock` | следующий свободный, например `127.0.0.1:9444` |

- У каждого inbound в Remnawave свой `target` — по нему nginx понимает, на какой порт пришёл клиент.
  `selfsteal-apps xray` печатает готовые `realitySettings` для каждого порта.
- Сертификат принадлежит домену и общий для всех его портов.
- Приложение (Jitsi, Nextcloud) живёт на одном адресе: `--port` при установке, при смене порта или домена
  старый адрес становится заглушкой 403. Адреса в приложениях (`PUBLIC_URL`, `OVERWRITEHOST`) и редирект
  http→https подставляются сами.
- По одному порту на один домен — одно содержимое. Разные приложения на разных портах одного домена работают,
  но cookies браузер делит по домену, поэтому надёжнее разные поддомены.
- Основной порт меняется только переустановкой без доменов. Установки ≤0.6 переносятся автоматически:
  все домены оказываются на основном порту, настройки Xray менять не нужно.

### Доступ по IP

```bash
sudo selfsteal-apps ip on meet.example.com [--port 444]   # https://<IP>[:444] показывает сайт этого домена
sudo selfsteal-apps ip off                   # по умолчанию: соединение без известного домена обрывается
sudo selfsteal-apps ip                       # текущий режим
```

То же — в меню «Домены». Во включённом режиме по `https://<IP>` (и по любому неизвестному имени) открывается
сайт выбранного домена с его сертификатом; браузер предупредит, что сертификат выдан не на IP, — после
подтверждения сайт откроется. Приложению при этом передаётся имя домена, поэтому Jitsi и Nextcloud работают.
Если выбранный домен удалить, показывается следующий домен с сертификатом. `http://<IP>` не меняется (404).

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

### Nextcloud

```bash
sudo selfsteal-apps app nextcloud install --domain cloud.example.com     # админ и пароль выведутся в конце
sudo selfsteal-apps app nextcloud user add ivan | passwd <имя> | del <имя> | list
sudo selfsteal-apps app nextcloud status | logs [app|db|redis|cron] | restart
sudo selfsteal-apps app nextcloud update        # патчи + мажорные версии по одной до текущего stable
sudo selfsteal-apps app nextcloud occ <...>     # любая команда occ
sudo selfsteal-apps app nextcloud uninstall     # удаляет и данные (тома); домен -> заглушка 403
```

- Официальный образ `nextcloud:<мажор>-apache` + MariaDB 11.8 + Redis + контейнер `cron` для фоновых задач.
- На домене — страница входа, **регистрации нет**. Загрузка файлов — до **100 МБ**.
- Мажорная версия фиксируется при установке (текущая `stable`). Nextcloud умеет обновляться только на одну
  мажорную версию за раз — `update` проходит их по очереди.
- Web — `127.0.0.1:8081` (если занят — берётся следующий свободный), реальный IP клиента доходит до Nextcloud
  (защита от перебора работает по нему). Нужно ~700 МБ RAM.
- Данные — в docker-томах проекта `ssa-nextcloud`, настройки — `/opt/selfsteal-apps/apps/nextcloud/`.

### Несколько приложений на одной ноде

Можно: каждое на своём домене и своём порту `127.0.0.1`. Один домен — одно приложение.
Перед установкой скрипт проверяет свободную память с учётом уже запущенного, `status` показывает все приложения
и сколько памяти они занимают.

## Диагностика: NAT на 443 от старого selfsteal

```bash
sudo selfsteal-apps doctor          # показать проблемы и предложить исправить (спрашивает перед каждым шагом)
sudo selfsteal-apps doctor --fix    # без терминала: исправить без вопросов
```

Старый selfsteal (DigneZzZ) продлевает сертификаты через TLS-ALPN на боковом порту (8443/9443/…): каждую ночь
cron запускает `/opt/nginx-selfsteal/acme-renew.sh`, который ставит `iptables -t nat … --dport 443 -j REDIRECT`,
вызывает acme.sh и снимает правило. В скрипте `set -e`, поэтому если acme.sh падает (например, на боковом порту
уже никто не слушает), правило остаётся — весь TCP/443 уходит на мёртвый порт мимо Xray, «Connection refused».
Продление пытается пройти только когда сертификат подходит к сроку, поэтому проблема возвращается раз в ~2 месяца.

Порты Xray берутся из системы (`ss`: процессы `rw-core` / `xray`), поэтому учитываются ноды с несколькими
inbound (443, 444, 8443, 9443…). Каждое перенаправление (iptables, ip6tables, nft) оценивается по тому, откуда и куда
оно ведёт: с порта Xray куда угодно — даже в другой inbound — 🔴 ломает этот inbound; с 443 в порт, где никто не
слушает (Xray не на 443), — 🟡 мусор; в порт Xray с другого порта — показывается, но не трогается.

Сокеты Xray → nginx: `doctor` проверяет, что файл каждого сокета на месте и nginx его слушает, и что контейнер
с Xray (remnanode) видит их у себя внутри (том `/dev/shm:/dev/shm` смонтирован и контейнер пересоздан после его
добавления — `docker restart` тома не применяет, нужен `docker compose up -d --force-recreate`). Если сокет пропал
при перезагрузке конфига, скрипт сам пересоздаёт контейнер nginx; на главном экране проблема видна красной строкой.

Для каждого публичного порта с доменами `doctor` проверяет связь Xray → nginx (по логам nginx за сутки): слушает
ли Xray этот порт; не присылает ли inbound трафик без proxy protocol (в его `realitySettings` нужен `"xver": 1`);
доходят ли вообще запросы — если за сутки пусто, откройте сайт в браузере и проверьте снова: пусто — значит
у inbound неверный `target` (нужный `doctor` покажет).

Ещё `doctor` находит задания
`acme-renew.sh` в cron и пропавшее задание нашего автопродления (установщик DigneZzZ удаляет из cron все строки
со словом `acme`). Удаляет только эти правила — Docker (`DOCKER*`) и остальные не трогает; cron-задания
комментирует, копия crontab сохраняется в `/etc/selfsteal-apps/`. Та же проверка запускается перед `install` и
`adopt`, а на главном экране появляется красная строка, если что-то найдено. selfsteal-apps сам NAT не использует.

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
| `/etc/selfsteal-apps/domains/<домен>@<порт>.env` | по файлу на сайт (домен + публичный порт) |
| `/etc/selfsteal-apps/acme/` | acme.sh и его данные |
| `/opt/selfsteal-apps/apps/<имя>/` | данные приложений |
| `/opt/selfsteal-apps/nginx/` | docker-compose, nginx.conf, `conf.d/sites/<домен>.conf` (все порты домена) — пересоздаются при каждом изменении, руками не править |
| `/opt/selfsteal-apps/nginx/ssl/` | сертификаты: `<домен>/` и `star.<зона>/` (wildcard) |
| `/etc/selfsteal-apps/cloudflare/` | токены Cloudflare по зонам |
| `/var/log/selfsteal-apps.log` | журнал действий скрипта |

Логи nginx — в `docker logs selfsteal-nginx` (с ротацией 3×10 МБ), реальный IP клиента берётся из proxy_protocol.

## Требования

Debian/Ubuntu (или другой Linux с systemd/cron), root, Docker + Compose v2 (предложит поставить), curl, openssl, git.

## Планы

Matrix + Element как модуль `apps/<name>/`, центральная раздача сертификатов на ноды,
relay-режим (свой 443, маршрутизация по SNI / секретным путям на зарубежную ноду).

## Лицензия

MIT. Определение `/dev/shm` у контейнеров Xray и общая схема nginx-selfsteal основаны на
[DigneZzZ/remnawave-scripts](https://github.com/DigneZzZ/remnawave-scripts) (MIT).
