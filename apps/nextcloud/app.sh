# shellcheck shell=bash
# Nextcloud (official "nextcloud" image, apache variant) + MariaDB + Redis + cron
# behind selfsteal-apps nginx.
#
#   TCP/443 -> Xray Reality -> nginx (TLS) -> 127.0.0.1:N_HTTP_PORT (nextcloud apache)
#
# Versions: the Nextcloud major is pinned (e.g. 34-apache). Nextcloud can only be
# upgraded one major at a time, so "update" walks major by major up to the image's
# current "stable". MariaDB is pinned to a major supported by Nextcloud.

nextcloud_TITLE="Nextcloud"
nextcloud_DESC="облачное хранилище (вход только по логину)"
nextcloud_MEM_MB=700

N_DIR="$APPS_DATA_DIR/nextcloud"
N_COMPOSE="$N_DIR/docker-compose.yml"
N_ENV="$N_DIR/.env"
N_STATE="$APPS_STATE_DIR/nextcloud.env"
N_PROJECT="ssa-nextcloud"
N_DB_IMAGE="mariadb:11.8"
N_REDIS_IMAGE="redis:8-alpine"
N_UPLOAD_LIMIT="100M"
N_LIBRARY_URL="https://raw.githubusercontent.com/docker-library/official-images/master/library/nextcloud"

N_KEYS=(N_DOMAIN N_MAJOR N_HTTP_PORT N_ADMIN N_INSTALLED_AT)
N_DOMAIN=""; N_MAJOR=""; N_HTTP_PORT="8081"; N_ADMIN="admin"; N_INSTALLED_AT=""

nextcloud_installed() { [[ -f "$N_STATE" && -f "$N_COMPOSE" ]]; }

_n_load() {
  # shellcheck disable=SC1090
  [[ -f "$N_STATE" ]] && source "$N_STATE"
  return 0
}
_n_save() { install -d -m 700 "$APPS_STATE_DIR"; _write_env "$N_STATE" "${N_KEYS[@]}"; }

_n_compose() { docker compose -p "$N_PROJECT" --project-directory "$N_DIR" --env-file "$N_ENV" -f "$N_COMPOSE" "$@"; }

_n_occ() { _n_compose exec -T -u www-data app php occ "$@"; }

# Major version behind the image's "stable" tag (from docker-library metadata).
_n_stable_major() {
  local lib
  lib="$(curl -fsSL --max-time 15 "$N_LIBRARY_URL" 2>/dev/null)" || return 1
  # no early "exit" in awk: with pipefail a closed pipe would fail the caller
  awk '/^Tags:/ && /(^|[ ,])stable([ ,]|$)/ && !done { for (i=2;i<=NF;i++) { t=$i; gsub(/,/,"",t); if (t ~ /^[0-9]+$/) { print t; done=1; break } } }' <<<"$lib"
}

_n_secret() { openssl rand -hex 24; }

_n_env_get() { [[ -f "$N_ENV" ]] || return 0; sed -n -E "s/^${1}=(.*)$/\1/p" "$N_ENV" | tail -1; }

_n_write_env() {
  local root pass admin_pass
  root="$(_n_env_get MYSQL_ROOT_PASSWORD)"; pass="$(_n_env_get MYSQL_PASSWORD)"; admin_pass="$(_n_env_get NEXTCLOUD_ADMIN_PASSWORD)"
  [[ -n "$root" ]] || root="$(_n_secret)"
  [[ -n "$pass" ]] || pass="$(_n_secret)"
  [[ -n "$admin_pass" ]] || admin_pass="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  local overwrite_host="" url="https://${N_DOMAIN}"
  if [[ "$PUBLIC_PORT" != 443 ]]; then overwrite_host="${N_DOMAIN}:${PUBLIC_PORT}"; url="https://${N_DOMAIN}:${PUBLIC_PORT}"; fi
  install -d -m 700 "$N_DIR"
  ( umask 077
    cat > "$N_ENV" <<EOF
# Managed by selfsteal-apps (secrets are generated once and kept)
NC_IMAGE=nextcloud:${N_MAJOR}-apache
DB_IMAGE=${N_DB_IMAGE}
REDIS_IMAGE=${N_REDIS_IMAGE}
HTTP_PORT=${N_HTTP_PORT}
MYSQL_ROOT_PASSWORD=${root}
MYSQL_PASSWORD=${pass}
NEXTCLOUD_ADMIN_USER=${N_ADMIN}
NEXTCLOUD_ADMIN_PASSWORD=${admin_pass}
NEXTCLOUD_TRUSTED_DOMAINS=${N_DOMAIN}
OVERWRITEPROTOCOL=https
OVERWRITEHOST=${overwrite_host}
OVERWRITECLIURL=${url}
TZ=$(_n_host_tz)
EOF
  )
}

_n_host_tz() {
  local tz=""
  [[ -f /etc/timezone ]] && tz="$(tr -d '[:space:]' </etc/timezone)"
  [[ -z "$tz" ]] && have timedatectl && tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  printf '%s' "${tz:-UTC}"
}

_n_write_compose() {
  cat > "$N_COMPOSE" <<'EOF'
# Managed by selfsteal-apps — regenerated on install/update.
services:
  db:
    image: ${DB_IMAGE}
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --skip-log-bin
    environment:
      MARIADB_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MARIADB_DATABASE: nextcloud
      MARIADB_USER: nextcloud
      MARIADB_PASSWORD: ${MYSQL_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 30
    logging: &logging
      driver: json-file
      options: { max-size: "10m", max-file: "3" }

  redis:
    image: ${REDIS_IMAGE}
    restart: unless-stopped
    logging: *logging

  app:
    image: ${NC_IMAGE}
    restart: unless-stopped
    ports:
      - "127.0.0.1:${HTTP_PORT}:80"
    depends_on:
      db: { condition: service_healthy }
      redis: { condition: service_started }
    volumes:
      - html:/var/www/html
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      REDIS_HOST: redis
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: ${NEXTCLOUD_TRUSTED_DOMAINS}
      OVERWRITEPROTOCOL: ${OVERWRITEPROTOCOL}
      OVERWRITEHOST: ${OVERWRITEHOST}
      OVERWRITECLIURL: ${OVERWRITECLIURL}
      TRUSTED_PROXIES: "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
      APACHE_DISABLE_REWRITE_IP: "1"
      PHP_UPLOAD_LIMIT: 100M
      PHP_MEMORY_LIMIT: 512M
      TZ: ${TZ}
    logging: *logging

  cron:
    image: ${NC_IMAGE}
    restart: unless-stopped
    entrypoint: /cron.sh
    depends_on:
      - app
    volumes:
      - html:/var/www/html
    environment:
      TZ: ${TZ}
    logging: *logging

volumes:
  db:
  html:
EOF
}

# Waits until status.php says installed and not in maintenance (first install / major upgrade).
_n_wait_ready() {
  local i body want="${1:-}"
  info "Жду Nextcloud на 127.0.0.1:${N_HTTP_PORT} (первый запуск/обновление занимает 1–3 минуты)..."
  for i in $(seq 1 120); do
    body="$(curl -fsS --max-time 3 -H "Host: ${N_DOMAIN}" "http://127.0.0.1:${N_HTTP_PORT}/status.php" 2>/dev/null || true)"
    if grep -q '"installed":true' <<<"$body" && grep -q '"maintenance":false' <<<"$body" && grep -q '"needsDbUpgrade":false' <<<"$body"; then
      if [[ -z "$want" ]] || grep -q "\"versionstring\":\"${want}\." <<<"$body"; then
        log "Nextcloud отвечает ($(sed -n 's/.*"versionstring":"\([^"]*\)".*/\1/p' <<<"$body"))."
        return 0
      fi
    fi
    sleep 3
  done
  _n_compose ps >&2 || true
  _n_compose logs --tail 40 app >&2 || true
  die "Nextcloud не поднялся на 127.0.0.1:${N_HTTP_PORT}."
}

_n_post_setup() {
  _n_occ background:cron >/dev/null || warn "Не удалось включить фоновые задачи через cron."
  _n_occ config:system:set maintenance_window_start --type=integer --value=1 >/dev/null || true
  # no "get your own free account" links on public pages
  _n_occ config:app:set core simpleSignUpLink.shown --value=false >/dev/null 2>&1 ||
    _n_occ config:system:set simpleSignUpLink.shown --type=boolean --value=false >/dev/null 2>&1 || true
  _n_occ db:add-missing-indices >/dev/null 2>&1 || true
  _n_occ maintenance:repair --include-expensive >/dev/null 2>&1 || true
}

_n_pick_port() {
  local p="$1"
  while port_in_use_tcp "$p"; do p=$((p+1)); done
  printf '%s' "$p"
}

# nextcloud install [--domain D] [--admin NAME] [--http-port P] [--major N]
nextcloud_install() {
  local d_arg="" admin_arg="" port_arg="" major_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) d_arg="${2:-}"; shift 2;;
      --admin) admin_arg="${2:-}"; shift 2;;
      --http-port) port_arg="${2:-}"; shift 2;;
      --major) major_arg="${2:-}"; shift 2;;
      -y|--yes) ASSUME_YES=1; shift;;
      *) die "nextcloud install: неизвестная опция $1";;
    esac
  done

  _n_load
  local reinstall=0; nextcloud_installed && reinstall=1
  title "Nextcloud$( (( reinstall )) && echo ' — переконфигурация')"
  (( reinstall )) || app_check_memory nextcloud

  [[ -n "$d_arg" ]] && N_DOMAIN="$d_arg"
  [[ -n "$N_DOMAIN" ]] || ask N_DOMAIN "Домен для Nextcloud (например cloud.example.com)"
  N_DOMAIN="$(lower "$N_DOMAIN")"
  valid_domain "$N_DOMAIN" || die "Некорректный домен: '$N_DOMAIN'"
  _app_domain_conflict nextcloud "$N_DOMAIN"

  if (( ! reinstall )); then
    [[ -n "$admin_arg" ]] && N_ADMIN="$admin_arg"
    [[ -n "$admin_arg" ]] || ask N_ADMIN "Имя администратора" "$N_ADMIN"
    [[ "$N_ADMIN" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "Некорректное имя администратора."

    if [[ -n "$port_arg" ]]; then
      valid_port "$port_arg" || die "--http-port"
      port_in_use_tcp "$port_arg" && die "Порт 127.0.0.1:$port_arg занят ($(port_owner_tcp "$port_arg"))."
      N_HTTP_PORT="$port_arg"
    else
      local free; free="$(_n_pick_port "$N_HTTP_PORT")"
      [[ "$free" != "$N_HTTP_PORT" ]] && warn "Порт $N_HTTP_PORT занят — беру $free."
      N_HTTP_PORT="$free"
    fi

    if [[ -n "$major_arg" ]]; then N_MAJOR="$major_arg"
    else
      N_MAJOR="$(_n_stable_major)"
      [[ -n "$N_MAJOR" ]] || die "Не удалось определить текущую stable-версию Nextcloud."
    fi
    [[ "$N_MAJOR" =~ ^[0-9]+$ ]] || die "Некорректная версия: $N_MAJOR"
  fi

  info "Nextcloud ${N_MAJOR} | домен: $N_DOMAIN | web: 127.0.0.1:$N_HTTP_PORT | БД: $N_DB_IMAGE | загрузка до $N_UPLOAD_LIMIT"
  _n_write_env
  _n_write_compose
  _n_compose config -q || die "docker compose config не прошёл."
  N_INSTALLED_AT="${N_INSTALLED_AT:-$(date +%F)}"
  _n_save

  info "Скачиваю образы и запускаю..."
  _n_compose --progress quiet pull -q || warn "pull завершился с ошибкой — пробую запустить с тем, что есть."
  _n_compose --progress quiet up -d --remove-orphans || die "docker compose up не удался."
  _n_wait_ready
  _n_post_setup

  domain_ensure "$N_DOMAIN" nextcloud "http://127.0.0.1:${N_HTTP_PORT}"

  log "Nextcloud готов: https://${N_DOMAIN}$([[ "$PUBLIC_PORT" != 443 ]] && echo ":$PUBLIC_PORT")"
  if (( ! reinstall )); then
    printf '   Администратор: %s%s%s   Пароль: %s%s%s\n' "$C_BOLD" "$N_ADMIN" "$C_RESET" "$C_BOLD" "$(_n_env_get NEXTCLOUD_ADMIN_PASSWORD)" "$C_RESET"
    info "Пароль также сохранён в $N_ENV (доступен только root). Сменить: selfsteal-apps app nextcloud user passwd $N_ADMIN"
  fi
}

nextcloud_update() {
  nextcloud_installed || die "Nextcloud не установлен."
  _n_load
  local stable; stable="$(_n_stable_major)"
  [[ "$stable" =~ ^[0-9]+$ ]] || die "Не удалось определить stable-версию Nextcloud."

  if (( N_MAJOR > stable )); then
    warn "Установлена $N_MAJOR — новее stable ($stable). Обновляю патчи в пределах $N_MAJOR."
    stable="$N_MAJOR"
  fi
  # same major first: picks up patch releases
  while :; do
    info "Nextcloud ${N_MAJOR}: скачиваю образ..."
    _n_write_env; _n_write_compose; _n_save
    _n_compose --progress quiet pull -q || die "Не удалось скачать nextcloud:${N_MAJOR}-apache."
    _n_compose --progress quiet up -d --remove-orphans
    _n_wait_ready "$N_MAJOR"
    (( N_MAJOR < stable )) || break
    N_MAJOR=$((N_MAJOR + 1))
    info "Мажорное обновление -> ${N_MAJOR} (только по одной версии за раз)."
  done
  _n_post_setup
  log "Nextcloud обновлён: $N_MAJOR (stable: $stable)."
}

nextcloud_uninstall() {
  nextcloud_installed || { info "Nextcloud не установлен."; return 0; }
  _n_load
  warn "Будут удалены контейнеры Nextcloud, база, все файлы пользователей (тома) и образы."
  confirm "Удалить Nextcloud?" n || return 0
  _n_compose down -v --remove-orphans --rmi all >/dev/null 2>&1 || _n_compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${N_DIR:?}" "$N_STATE"
  domain_release "$N_DOMAIN" nextcloud
  log "Nextcloud удалён."
}

nextcloud_status() {
  nextcloud_installed || { info "Nextcloud не установлен. Установить: selfsteal-apps app nextcloud install"; return 0; }
  _n_load
  title "Nextcloud"
  printf ' Домен:   https://%s\n' "$N_DOMAIN"
  local body ver
  body="$(curl -fsS --max-time 3 -H "Host: ${N_DOMAIN}" "http://127.0.0.1:${N_HTTP_PORT}/status.php" 2>/dev/null || true)"
  ver="$(sed -n 's/.*"versionstring":"\([^"]*\)".*/\1/p' <<<"$body")"
  printf ' Версия:  %s (ветка %s)\n' "${ver:-?}" "$N_MAJOR"
  printf ' Web:     127.0.0.1:%s ' "$N_HTTP_PORT"
  if grep -q '"maintenance":true' <<<"$body"; then printf '%sрежим обслуживания%s\n' "$C_YELLOW" "$C_RESET"
  elif [[ -n "$ver" ]]; then printf '%sOK%s\n' "$C_GREEN" "$C_RESET"
  else printf '%sне отвечает%s\n' "$C_RED" "$C_RESET"
  fi
  printf ' БД:      %s, загрузка до %s\n' "$N_DB_IMAGE" "$N_UPLOAD_LIMIT"
  [[ -n "$ver" ]] && printf ' Пользователи: %s\n' "$(_n_user_names | tr '\n' ' ')"
  echo
  _n_compose ps --format 'table {{.Service}}\t{{.Status}}' 2>/dev/null || true
}

nextcloud_brief() { _n_load; printf '%s' "$N_DOMAIN"; }

nextcloud_logs() {
  nextcloud_installed || die "Nextcloud не установлен."
  local svc="${1:-}"
  if [[ -n "$svc" ]]; then
    [[ "$svc" =~ ^(app|db|redis|cron)$ ]] || die "Сервис: app | db | redis | cron"
    _n_compose logs -f --tail 200 "$svc"
  else
    _n_compose logs -f --tail 100
  fi
}

# --- users ---------------------------------------------------------------------

_n_valid_user() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$ ]]; }

_n_user_names() { _n_occ user:list --output=json 2>/dev/null | grep -oE '"[^"]+":' | tr -d '":' || true; }

_n_gen_pass() { openssl rand -base64 18 | tr -d '/+=' | cut -c1-20; }

_n_user_add() {
  local u="$1" p="${2:-}" gen=0
  _n_valid_user "$u" || die "Имя: латиница/цифры/._@- (до 64 символов)."
  [[ -n "$p" ]] || { p="$(_n_gen_pass)"; gen=1; }
  _n_compose exec -T -u www-data -e OC_PASS="$p" app php occ user:add --password-from-env "$u" >/dev/null ||
    die "Не удалось создать $u (уже есть? слабый пароль?)."
  log "Пользователь $u: создан."
  (( gen )) && printf '   Логин: %s%s%s   Пароль: %s%s%s\n' "$C_BOLD" "$u" "$C_RESET" "$C_BOLD" "$p" "$C_RESET"
  return 0
}

_n_user_passwd() {
  local u="$1" p="${2:-}" gen=0
  _n_valid_user "$u" || die "Некорректное имя."
  [[ -n "$p" ]] || { p="$(_n_gen_pass)"; gen=1; }
  _n_compose exec -T -u www-data -e OC_PASS="$p" app php occ user:resetpassword --password-from-env "$u" >/dev/null ||
    die "Не удалось сменить пароль $u."
  log "Пользователь $u: пароль обновлён."
  (( gen )) && printf '   Логин: %s%s%s   Пароль: %s%s%s\n' "$C_BOLD" "$u" "$C_RESET" "$C_BOLD" "$p" "$C_RESET"
  return 0
}

nextcloud_cmd() {
  local sub="$1"; shift
  nextcloud_installed || die "Nextcloud не установлен."
  _n_load
  case "$sub" in
    user|users)
      local act="${1:-list}"; shift || true
      local u="${1:-}"
      case "$act" in
        list|ls) _n_user_names ;;
        add)    [[ -n "$u" ]] || ask u "Имя пользователя"; _n_user_add "$u" "${2:-}" ;;
        passwd) [[ -n "$u" ]] || ask u "Имя пользователя"; _n_user_passwd "$u" "${2:-}" ;;
        del|rm|remove)
          [[ -n "$u" ]] || ask u "Имя пользователя"
          _n_valid_user "$u" || die "Некорректное имя."
          [[ "$u" == "$N_ADMIN" ]] && warn "Это администратор, созданный при установке."
          confirm "Удалить пользователя $u вместе с его файлами?" n && { _n_occ user:delete "$u" >/dev/null && log "Пользователь $u удалён."; } ;;
        *) die "nextcloud user: list | add <имя> [пароль] | passwd <имя> [пароль] | del <имя>";;
      esac
      ;;
    occ) _n_occ "$@" ;;
    restart) _n_compose restart >/dev/null && log "Nextcloud перезапущен." ;;
    *) die "nextcloud: install | status | logs [app|db|redis|cron] | update | user ... | occ <args> | restart | uninstall";;
  esac
}

nextcloud_menu_extra() {
  printf '  6) Пользователи: список\n  7) Добавить пользователя\n  8) Сменить пароль\n  9) Удалить пользователя\n'
}

nextcloud_menu_action() {
  case "$1" in
    6) nextcloud_cmd user list ;;
    7) nextcloud_cmd user add ;;
    8) nextcloud_cmd user passwd ;;
    9) nextcloud_cmd user del ;;
    *) return 2 ;;
  esac
}

nextcloud_nginx_locations() {
  local up="${UPSTREAM:-http://127.0.0.1:8081}"
  cat <<EOF
    client_max_body_size 100m;
    client_body_timeout 300s;
    add_header Strict-Transport-Security "max-age=15552000" always;

    location = /.well-known/carddav { return 301 /remote.php/dav/; }
    location = /.well-known/caldav  { return 301 /remote.php/dav/; }

    location / {
        proxy_pass ${up};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
EOF
}
