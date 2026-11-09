# shellcheck shell=bash
# Jitsi Meet (docker-jitsi-meet) behind selfsteal-apps nginx.
#
#   TCP/443  -> Xray Reality -> nginx (TLS, real cert) -> 127.0.0.1:J_HTTP_PORT (jitsi web)
#   UDP/JVB  -> Jitsi Videobridge, published directly (media)
#
# Releases: the newest "stable-*" tag of jitsi/docker-jitsi-meet; compose and images
# come from the same tag, so they always match.

jitsi_TITLE="Jitsi Meet"
jitsi_DESC="видеоконференции (комнаты создают только пользователи)"

J_REPO_URL="https://github.com/jitsi/docker-jitsi-meet.git"
J_DIR="$APPS_DATA_DIR/jitsi"
J_SRC="$J_DIR/src"
J_CFG="$J_DIR/config"
J_OVERRIDE="$J_DIR/docker-compose.override.yml"
J_STATE="$APPS_STATE_DIR/jitsi.env"
J_PROJECT="ssa-jitsi"
J_XMPP_DOMAIN="meet.jitsi"

J_KEYS=(J_DOMAIN J_TAG J_HTTP_PORT J_JVB_PORT J_AUTH J_PUBLIC_IP J_INSTALLED_AT)
J_DOMAIN=""; J_TAG=""; J_HTTP_PORT="8000"; J_JVB_PORT="10000"; J_AUTH="1"; J_PUBLIC_IP=""; J_INSTALLED_AT=""

OLD_SJ_STATE="/etc/selfsteal-jitsi/state.env"
OLD_SJ_DIR="/opt/jitsi"
OLD_SJ_CFG="/root/.jitsi-meet-cfg"

jitsi_installed() { [[ -f "$J_STATE" && -f "$J_SRC/docker-compose.yml" ]]; }

_j_load()  {
  # shellcheck disable=SC1090
  [[ -f "$J_STATE" ]] && source "$J_STATE"
  return 0
}
_j_save()  { install -d -m 700 "$APPS_STATE_DIR"; _write_env "$J_STATE" "${J_KEYS[@]}"; }

_j_compose() {
  docker compose -p "$J_PROJECT" --project-directory "$J_SRC" --env-file "$J_SRC/.env" \
    -f "$J_SRC/docker-compose.yml" -f "$J_OVERRIDE" "$@"
}

_j_set_env() {
  local key="$1" val="$2" f="$J_SRC/.env"
  if grep -qE "^#?${key}=" "$f"; then
    # replace the first (possibly commented) occurrence, drop later duplicates
    awk -v k="$key" -v v="$val" '
      $0 ~ "^#?"k"=" { if (!done) { print k"="v; done=1 } ; next }
      { print }' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  else
    printf '%s=%s\n' "$key" "$val" >> "$f"
  fi
}
_j_unset_env() { sed -i -E "/^${1}=/d" "$J_SRC/.env"; }
_j_get_env()   { sed -n -E "s/^${1}=(.*)$/\1/p" "$J_SRC/.env" | tail -1; }

_j_latest_tag() {
  git ls-remote --tags --refs "$J_REPO_URL" 'stable-*' 2>/dev/null |
    awk -F/ '{print $3}' | sort -V | tail -1
}

_j_compose_supports_override() {
  local raw major minor patch
  raw="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
  IFS=. read -r major minor patch <<<"$raw"
  patch="${patch%%[!0-9]*}"
  major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
  (( major > 2 || (major == 2 && (minor > 24 || (minor == 24 && patch >= 4))) ))
}

_j_check_resources() {
  local mem_kb
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if (( mem_kb > 0 && mem_kb < 1800000 )); then
    warn "RAM: $((mem_kb/1024)) МБ. Jitsi (Java JVB + jicofo) комфортно работает от ~2 ГБ."
    confirm "Всё равно ставить?" y || die "Отменено."
  fi
}

_j_host_tz() {
  local tz=""
  [[ -f /etc/timezone ]] && tz="$(tr -d '[:space:]' </etc/timezone)"
  [[ -z "$tz" ]] && have timedatectl && tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [[ -z "$tz" && -L /etc/localtime ]] && tz="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
  printf '%s' "${tz:-UTC}"
}

_j_checkout() {
  local tag="$1"
  if [[ -d "$J_SRC/.git" ]]; then
    git -C "$J_SRC" fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag" || die "Не удалось скачать $tag."
    git -C "$J_SRC" -c advice.detachedHead=false checkout -q "$tag" || die "Не удалось переключиться на $tag."
  else
    install -d -m 755 "$J_DIR"
    git -c advice.detachedHead=false clone -q --depth 1 -b "$tag" "$J_REPO_URL" "$J_SRC" || die "Не удалось скачать docker-jitsi-meet $tag."
  fi
}

_j_prepare_env() {
  [[ -f "$J_SRC/.env" ]] || cp "$J_SRC/env.example" "$J_SRC/.env"
  chmod 600 "$J_SRC/.env"
  # Secrets only once: regenerating them on every run is pointless churn.
  if [[ -z "$(_j_get_env JICOFO_AUTH_PASSWORD)" ]]; then
    ( cd "$J_SRC" && bash ./gen-passwords.sh ) || die "gen-passwords.sh не отработал."
    rm -f "$J_SRC/.env.bak"
  fi

  _j_set_env CONFIG "$J_CFG"
  _j_set_env TZ "$(_j_host_tz)"
  _j_set_env PUBLIC_URL "https://${J_DOMAIN}$([[ "$PUBLIC_PORT" != 443 ]] && echo ":$PUBLIC_PORT")"
  _j_set_env HTTP_PORT "$J_HTTP_PORT"
  _j_set_env HTTPS_PORT "8443"
  _j_set_env DISABLE_HTTPS "1"
  _j_set_env ENABLE_HTTP_REDIRECT "0"
  _j_set_env ENABLE_LETSENCRYPT "0"
  _j_set_env ENABLE_IPV6 "0"          # works on hosts with IPv6 disabled
  _j_set_env JVB_ADVERTISE_IPS "$J_PUBLIC_IP"
  _j_set_env JVB_PORT "$J_JVB_PORT"
  # images come from the checked-out tag's compose defaults
  _j_unset_env JITSI_IMAGE_VERSION

  if [[ "$J_AUTH" == "1" ]]; then
    _j_set_env ENABLE_AUTH "1"
    _j_set_env AUTH_TYPE "internal"
    _j_set_env ENABLE_GUESTS "1"       # guests may join rooms an authenticated user opened
  else
    _j_set_env ENABLE_AUTH "0"
    _j_set_env ENABLE_GUESTS "0"
  fi

  install -d -m 755 "$J_CFG"/{web,jicofo,jvb,transcripts} \
    "$J_CFG"/prosody/{config,prosody-plugins-custom} \
    "$J_CFG"/storage/{web,transcripts,prosody} "$J_CFG"/tmp/web-load-test
  # Prosody runs as uid/gid 1000 and fails when /var/lib/prosody is root-owned.
  chown -R 1000:1000 "$J_CFG/storage/prosody"
}

_j_write_override() {
  cat > "$J_OVERRIDE" <<EOF
# Managed by selfsteal-apps: Jitsi web only on loopback, nginx in front of it.
services:
  web:
    ports: !override
      - "127.0.0.1:${J_HTTP_PORT}:8000"
EOF
}

_j_verify_compose() {
  local cfg web
  cfg="$(_j_compose config 2>&1)" || { printf '%s\n' "$cfg" >&2; die "docker compose config не прошёл."; }
  web="$(printf '%s\n' "$cfg" | awk '/^  web:$/ {p=1; print; next} p && /^  [a-z]/ {exit} p {print}')"
  grep -q 'host_ip: 127.0.0.1' <<<"$web" || die "Jitsi web не привязан к 127.0.0.1 — отмена."
  grep -q 'published: "8443"' <<<"$web" && die "Порт 8443 Jitsi опубликован наружу — override не применился."
  return 0
}

_j_wait_http() {
  local i
  info "Жду Jitsi web на 127.0.0.1:${J_HTTP_PORT}..."
  for i in $(seq 1 60); do
    curl -fsS --max-time 3 "http://127.0.0.1:${J_HTTP_PORT}/" >/dev/null 2>&1 && { log "Jitsi web отвечает."; return 0; }
    sleep 2
  done
  _j_compose ps >&2 || true
  _j_compose logs --tail 30 prosody web >&2 || true
  die "Jitsi web не поднялся на 127.0.0.1:${J_HTTP_PORT}."
}

_j_check_udp() {
  if _j_compose ps --format '{{.Service}} {{.Ports}}' 2>/dev/null | grep -E "^jvb .*:${J_JVB_PORT}->${J_JVB_PORT}/udp" >/dev/null; then
    log "JVB UDP/${J_JVB_PORT} опубликован."
  else
    warn "Не вижу публикации UDP/${J_JVB_PORT} у JVB."
  fi
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ! ufw status | grep -qE "^${J_JVB_PORT}/udp"; then
      warn "ufw активен, а UDP/${J_JVB_PORT} не разрешён — без него видео не пойдёт."
      confirm "Выполнить 'ufw allow ${J_JVB_PORT}/udp'?" y && ufw allow "${J_JVB_PORT}/udp" >/dev/null && log "ufw: UDP/${J_JVB_PORT} разрешён."
    fi
  fi
  info "Если у хостера есть внешний firewall/security group — откройте там UDP/${J_JVB_PORT}."
}

_j_old_present() { [[ -f "$OLD_SJ_STATE" && -f "$OLD_SJ_DIR/.env" ]]; }

# Import selfsteal-jitsi: same secrets, same Prosody accounts, stop the old stack.
_j_migrate_from_old() {
  title "Перенос Jitsi из selfsteal-jitsi"
  local DOMAIN_OLD="" PUBLIC_IP_OLD="" AUTH_OLD="" HTTP_PORT_OLD="" JVB_PORT_OLD=""
  # shellcheck disable=SC1090
  DOMAIN_OLD="$(sed -n "s/^DOMAIN='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$OLD_SJ_STATE")"
  PUBLIC_IP_OLD="$(sed -n "s/^PUBLIC_IP='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$OLD_SJ_STATE")"
  AUTH_OLD="$(sed -n "s/^AUTH='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$OLD_SJ_STATE")"
  HTTP_PORT_OLD="$(sed -n "s/^HTTP_PORT='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$OLD_SJ_STATE")"
  JVB_PORT_OLD="$(sed -n "s/^JVB_PORT='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$OLD_SJ_STATE")"

  [[ -z "$J_DOMAIN" ]] && J_DOMAIN="$DOMAIN_OLD"
  J_PUBLIC_IP="${J_PUBLIC_IP:-$PUBLIC_IP_OLD}"
  [[ -n "$AUTH_OLD" ]] && J_AUTH="$AUTH_OLD"
  valid_port "${HTTP_PORT_OLD:-x}" && J_HTTP_PORT="$HTTP_PORT_OLD"
  valid_port "${JVB_PORT_OLD:-x}" && J_JVB_PORT="$JVB_PORT_OLD"

  info "Домен: $J_DOMAIN, auth: $J_AUTH, web: 127.0.0.1:$J_HTTP_PORT, JVB: UDP/$J_JVB_PORT"
  info "Секреты (.env) и учётки Prosody будут перенесены, старый стек остановлен (файлы останутся)."
  confirm "Продолжить перенос?" y || return 1

  install -d -m 755 "$J_DIR"
  J_IMPORT_ENV="$OLD_SJ_DIR/.env"
  J_MIGRATE=1
  if [[ -d "$OLD_SJ_CFG" && ! -d "$J_CFG" ]]; then
    cp -a "$OLD_SJ_CFG" "$J_CFG"
    log "Конфиг и учётки скопированы из $OLD_SJ_CFG."
  fi
  return 0
}

# Called right before our stack starts: keeps downtime to the restart itself.
_j_stop_old() {
  info "Останавливаю старый стек $OLD_SJ_DIR..."
  if [[ -f "$OLD_SJ_DIR/docker-compose.selfsteal.yml" ]]; then
    (cd "$OLD_SJ_DIR" && docker compose -f docker-compose.yml -f docker-compose.selfsteal.yml down --remove-orphans) >/dev/null 2>&1 || true
  else
    (cd "$OLD_SJ_DIR" && docker compose down --remove-orphans) >/dev/null 2>&1 || true
  fi
  # accounts may have changed since the first copy
  if [[ -d "$OLD_SJ_CFG/storage/prosody" ]]; then
    cp -a "$OLD_SJ_CFG/storage/prosody/." "$J_CFG/storage/prosody/"
    chown -R 1000:1000 "$J_CFG/storage/prosody"
  fi
  mv -f "$OLD_SJ_STATE" "$OLD_SJ_STATE.migrated"
  log "selfsteal-jitsi остановлен (файлы в $OLD_SJ_DIR и $OLD_SJ_CFG оставлены)."
}

# jitsi install [--domain D] [--auth|--no-auth] [--http-port P] [--jvb-port P] [--tag stable-XXXX] [--no-migrate]
jitsi_install() {
  local tag="" no_migrate=0 d_arg="" auth_arg="" http_arg="" jvb_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) d_arg="${2:-}"; shift 2;;
      --auth) auth_arg=1; shift;;
      --no-auth) auth_arg=0; shift;;
      --http-port) http_arg="${2:-}"; shift 2;;
      --jvb-port) jvb_arg="${2:-}"; shift 2;;
      --tag) tag="${2:-}"; shift 2;;
      --no-migrate) no_migrate=1; shift;;
      -y|--yes) ASSUME_YES=1; shift;;
      *) die "jitsi install: неизвестная опция $1";;
    esac
  done

  _j_load
  local reinstall=0; jitsi_installed && reinstall=1
  title "Jitsi Meet$( (( reinstall )) && echo ' — переконфигурация')"

  _j_compose_supports_override || die "Нужен Docker Compose v2.24.4+ (сейчас: $(docker compose version --short))."
  have git || pkg_install git || die "git обязателен."
  (( reinstall )) || _j_check_resources

  J_IMPORT_ENV=""; J_MIGRATE=0
  if (( ! reinstall && ! no_migrate )) && _j_old_present; then
    warn "Найдена установка selfsteal-jitsi ($OLD_SJ_DIR)."
    if confirm "Перенести её (секреты, пользователи, порты)?" y; then
      _j_migrate_from_old || die "Отменено."
    fi
  fi

  [[ -n "$d_arg" ]] && J_DOMAIN="$d_arg"
  if [[ -z "$J_DOMAIN" ]]; then
    local cur; cur="$(list_domains | head -1)"
    ask J_DOMAIN "Домен для Jitsi" "$cur"
  fi
  J_DOMAIN="$(lower "$J_DOMAIN")"
  valid_domain "$J_DOMAIN" || die "Некорректный домен: '$J_DOMAIN'"

  if [[ -n "$auth_arg" ]]; then J_AUTH="$auth_arg"
  elif (( ! reinstall )) && [[ -z "$J_IMPORT_ENV" ]] && is_interactive; then
    confirm "Создавать комнаты только авторизованным пользователям (гости входят по ссылке)?" y && J_AUTH=1 || J_AUTH=0
  fi
  [[ -n "$http_arg" ]] && { valid_port "$http_arg" || die "--http-port"; J_HTTP_PORT="$http_arg"; }
  [[ -n "$jvb_arg" ]] && { valid_port "$jvb_arg" || die "--jvb-port"; J_JVB_PORT="$jvb_arg"; }

  if (( ! J_MIGRATE )) && port_in_use_tcp "$J_HTTP_PORT" && ! _j_compose ps -q web 2>/dev/null | grep -q .; then
    die "127.0.0.1:$J_HTTP_PORT занят ($(port_owner_tcp "$J_HTTP_PORT")). Укажите --http-port."
  fi

  J_PUBLIC_IP="${J_PUBLIC_IP:-${PUBLIC_IP:-$(detect_public_ip || true)}}"
  valid_ipv4 "$J_PUBLIC_IP" || ask J_PUBLIC_IP "Публичный IPv4 сервера (для JVB)" ""
  valid_ipv4 "$J_PUBLIC_IP" || die "Нужен публичный IPv4."

  if [[ -z "$tag" ]]; then
    if (( reinstall )) && [[ -n "$J_TAG" ]]; then tag="$J_TAG"
    else
      tag="$(_j_latest_tag)"; [[ -n "$tag" ]] || die "Не удалось получить список релизов docker-jitsi-meet."
    fi
  fi
  [[ "$tag" =~ ^stable-[0-9]+(-[0-9]+)?$ ]] || die "Некорректный тег: $tag"

  info "Релиз: $tag | домен: $J_DOMAIN | auth: $J_AUTH | web: 127.0.0.1:$J_HTTP_PORT | JVB: UDP/$J_JVB_PORT"
  _j_checkout "$tag"
  J_TAG="$tag"
  [[ -n "$J_IMPORT_ENV" && ! -f "$J_SRC/.env" ]] && install -m 600 "$J_IMPORT_ENV" "$J_SRC/.env"
  _j_prepare_env
  _j_write_override
  _j_verify_compose
  J_INSTALLED_AT="${J_INSTALLED_AT:-$(date +%F)}"
  _j_save

  info "Скачиваю образы и запускаю Jitsi..."
  _j_compose --progress quiet pull -q || warn "pull завершился с ошибкой — пробую запустить с тем, что есть."
  (( J_MIGRATE )) && _j_stop_old
  _j_compose --progress quiet up -d --remove-orphans || die "docker compose up не удался."
  _j_wait_http
  _j_check_udp

  domain_ensure "$J_DOMAIN" jitsi "http://127.0.0.1:${J_HTTP_PORT}"

  log "Jitsi Meet готов: https://${J_DOMAIN}$([[ "$PUBLIC_PORT" != 443 ]] && echo ":$PUBLIC_PORT")"
  if [[ "$J_AUTH" == "1" && "$(_j_user_names | wc -l)" -eq 0 ]]; then
    warn "Пользователей ещё нет — без них никто не сможет открыть комнату."
    if is_interactive && confirm "Создать пользователя сейчас?" y; then
      local u; ask u "Имя пользователя" "admin"
      _j_user_add "$u" ""
    else
      info "Создать: selfsteal-apps app jitsi user add <имя>"
    fi
  fi
}

jitsi_update() {
  local force=0; [[ "${1:-}" == "--force" ]] && force=1
  jitsi_installed || die "Jitsi не установлен."
  _j_load
  local latest; latest="$(_j_latest_tag)"
  [[ -n "$latest" ]] || die "Не удалось получить список релизов."
  if [[ "$latest" == "$J_TAG" ]] && (( ! force )); then
    log "Уже последняя версия: $J_TAG"
    return 0
  fi
  info "Обновление Jitsi: ${J_TAG} -> ${latest}"
  _j_checkout "$latest"
  J_TAG="$latest"
  _j_prepare_env
  _j_write_override
  _j_verify_compose
  _j_save
  _j_compose --progress quiet pull -q || die "Не удалось скачать образы $latest."
  _j_compose --progress quiet up -d --remove-orphans
  _j_wait_http
  _j_check_udp
  log "Jitsi обновлён до $latest."
}

jitsi_uninstall() {
  jitsi_installed || { info "Jitsi не установлен."; return 0; }
  _j_load
  warn "Будут удалены контейнеры Jitsi, $J_DIR (конфиг, пользователи) и образы."
  confirm "Удалить Jitsi?" n || return 0
  _j_compose down --remove-orphans --rmi all >/dev/null 2>&1 || _j_compose down --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${J_DIR:?}" "$J_STATE"
  domain_release "$J_DOMAIN" jitsi
  log "Jitsi удалён."
}

jitsi_status() {
  jitsi_installed || { info "Jitsi не установлен. Установить: selfsteal-apps app jitsi install"; return 0; }
  _j_load
  title "Jitsi Meet"
  printf ' Домен:   https://%s\n' "$J_DOMAIN"
  printf ' Релиз:   %s\n' "$J_TAG"
  printf ' Auth:    %s\n' "$( [[ $J_AUTH == 1 ]] && echo "только пользователи создают комнаты, гости по ссылке" || echo "открытый (любой может создать комнату)")"
  printf ' Web:     127.0.0.1:%s ' "$J_HTTP_PORT"
  curl -fsS --max-time 3 "http://127.0.0.1:${J_HTTP_PORT}/" >/dev/null 2>&1 &&
    printf '%sOK%s\n' "$C_GREEN" "$C_RESET" || printf '%sне отвечает%s\n' "$C_RED" "$C_RESET"
  printf ' JVB:     UDP/%s, IP %s\n' "$J_JVB_PORT" "$J_PUBLIC_IP"
  [[ "$J_AUTH" == "1" ]] && printf ' Пользователи: %s\n' "$(_j_user_names | tr '\n' ' ')"
  echo
  _j_compose ps --format 'table {{.Service}}\t{{.Status}}' 2>/dev/null || true
}

jitsi_logs() {
  jitsi_installed || die "Jitsi не установлен."
  local svc="${1:-}"
  if [[ -n "$svc" ]]; then
    [[ "$svc" =~ ^(web|prosody|jicofo|jvb)$ ]] || die "Сервис: web | prosody | jicofo | jvb"
    _j_compose logs -f --tail 200 "$svc"
  else
    _j_compose logs -f --tail 100
  fi
}

# --- users (Prosody internal auth) ----------------------------------------

_j_valid_user() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; }

# Newer images render the config to /run/prosody/config (read-only rootfs), older ones to /config.
_j_prosodyctl() {
  # shellcheck disable=SC2016  # expanded inside the container's shell
  _j_compose exec -T prosody sh -c '
    for c in /run/prosody/config/prosody.cfg.lua /config/prosody.cfg.lua; do
      [ -f "$c" ] && exec prosodyctl --config "$c" "$@"
    done
    echo "prosody.cfg.lua not found" >&2; exit 1' prosodyctl "$@"
}

_j_user_names() {
  local host="${J_XMPP_DOMAIN//./%2e}" d f
  # newer images keep data in /var/lib/prosody/data/<host>, older ones in /var/lib/prosody/<host>
  shopt -s nullglob
  for d in "$J_CFG/storage/prosody/data/$host/accounts" "$J_CFG/storage/prosody/$host/accounts"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*.dat; do basename "$f" .dat; done
  done | sort -u
  shopt -u nullglob
}

_j_gen_pass() { openssl rand -base64 18 | tr -d '/+=' | cut -c1-20; }

_j_user_add() {
  local u="$1" p="${2:-}" gen=0 verb="${3:-создан}"
  _j_valid_user "$u" || die "Имя: латиница/цифры/._- (до 64 символов)."
  [[ -n "$p" ]] || { p="$(_j_gen_pass)"; gen=1; }
  _j_prosodyctl register "$u" "$J_XMPP_DOMAIN" "$p" >/dev/null || die "Не удалось создать пользователя $u."
  log "Пользователь $u: $verb."
  (( gen )) && printf '   Логин: %s%s%s   Пароль: %s%s%s\n' "$C_BOLD" "$u" "$C_RESET" "$C_BOLD" "$p" "$C_RESET"
  return 0
}

_j_user_del() {
  local u="$1"
  _j_valid_user "$u" || die "Некорректное имя."
  _j_prosodyctl unregister "$u" "$J_XMPP_DOMAIN" >/dev/null || die "Не удалось удалить $u."
  log "Пользователь $u удалён."
}

jitsi_cmd() {
  local sub="$1"; shift
  jitsi_installed || die "Jitsi не установлен."
  _j_load
  case "$sub" in
    user|users)
      local act="${1:-list}"; shift || true
      case "$act" in
        list|ls) _j_user_names ;;
        add)    local u="${1:-}"; [[ -n "$u" ]] || ask u "Имя пользователя"; _j_user_add "$u" "${2:-}" ;;
        passwd) local u="${1:-}"; [[ -n "$u" ]] || ask u "Имя пользователя"
                _j_user_names | grep -qx "$u" || die "Нет пользователя $u."
                _j_user_add "$u" "${2:-}" "пароль обновлён" ;;   # register overwrites the password
        del|rm|remove) local u="${1:-}"; [[ -n "$u" ]] || ask u "Имя пользователя"
                confirm "Удалить пользователя $u?" n && _j_user_del "$u" ;;
        *) die "jitsi user: list | add <имя> [пароль] | passwd <имя> [пароль] | del <имя>";;
      esac
      ;;
    restart) _j_compose restart >/dev/null && log "Jitsi перезапущен." ;;
    *) die "jitsi: install | status | logs [svc] | update [--force] | user ... | restart | uninstall";;
  esac
}

jitsi_menu_extra() {
  printf '  6) Пользователи: список\n  7) Добавить пользователя\n  8) Сменить пароль\n  9) Удалить пользователя\n'
}

jitsi_menu_action() {
  case "$1" in
    6) jitsi_cmd user list ;;
    7) jitsi_cmd user add ;;
    8) jitsi_cmd user passwd ;;
    9) jitsi_cmd user del ;;
    *) return 2 ;;
  esac
}

jitsi_nginx_locations() {
  local up="${UPSTREAM:-http://127.0.0.1:8000}"
  cat <<EOF
    client_max_body_size 8m;

    location = /xmpp-websocket {
        proxy_pass ${up}/xmpp-websocket\$is_args\$args;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
        tcp_nodelay on;
    }

    location ^~ /colibri-ws/ {
        proxy_pass ${up};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
        tcp_nodelay on;
    }

    location / {
        proxy_pass ${up};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 300s;
    }
EOF
}
