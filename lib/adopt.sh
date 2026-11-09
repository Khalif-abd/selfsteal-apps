# shellcheck shell=bash
# Take over an existing DigneZzZ nginx-selfsteal install (optionally patched by
# selfsteal-jitsi) without touching Xray/remnanode: same socket, same xver.

OLD_DIR="${SSA_OLD_SELFSTEAL_DIR:-/opt/nginx-selfsteal}"
OLD_CONTAINER="nginx-selfsteal"
OLD_JITSI_STATE="/etc/selfsteal-jitsi/state.env"

adopt_detect() { [[ -f "$OLD_DIR/docker-compose.yml" && -f "$OLD_DIR/conf.d/selfsteal.conf" ]]; }

adopt_cmd() {
  adopt_detect || die "nginx-selfsteal не найден в $OLD_DIR."
  ensure_docker
  local conf="$OLD_DIR/conf.d/selfsteal.conf"

  title "Перенос nginx-selfsteal → selfsteal-apps"

  local d listen
  d="$(awk '/^[[:space:]]*server_name[[:space:]]+/ { for (i=2;i<=NF;i++) { gsub(/;/,"",$i); if ($i !~ /^_/ && $i !~ /^\$/) { print $i; exit } } }' "$conf")"
  d="$(lower "$d")"
  valid_domain "$d" || die "Не смог определить домен из $conf."

  listen="$(grep -m1 -oE 'listen[[:space:]]+(unix:[^ ;]+|127\.0\.0\.1:[0-9]+)' "$conf" | awk '{print $2}')"
  if [[ "$listen" == unix:* ]]; then
    LISTEN_MODE="socket"; SOCKET_PATH="${listen#unix:}"
  elif [[ "$listen" == 127.0.0.1:* ]]; then
    LISTEN_MODE="tcp"; TCP_PORT="${listen##*:}"
  else
    die "Не смог определить listen (socket/tcp) из $conf."
  fi
  grep -qE 'listen[^;]*proxy_protocol' "$conf" && PROXY_PROTOCOL="1" || PROXY_PROTOCOL="0"

  # Cert: map container path (/etc/nginx/ssl/...) to host ($OLD_DIR/ssl/...)
  local crt key
  crt="$(awk '/ssl_certificate[[:space:]]/ && !/ssl_certificate_key/ {gsub(/;/,"",$2); print $2; exit}' "$conf")"
  key="$(awk '/ssl_certificate_key[[:space:]]/ {gsub(/;/,"",$2); print $2; exit}' "$conf")"
  crt="${crt/#\/etc\/nginx\/ssl/$OLD_DIR/ssl}"
  key="${key/#\/etc\/nginx\/ssl/$OLD_DIR/ssl}"

  # What the domain currently serves
  local app="stub" upstream="" jitsi_port=""
  if [[ -f "$OLD_JITSI_STATE" ]]; then
    jitsi_port="$(sed -n "s/^HTTP_PORT='\{0,1\}\([0-9]*\).*/\1/p" "$OLD_JITSI_STATE")"
    app="proxy"; upstream="http://127.0.0.1:${jitsi_port:-8000}"
  elif grep -qE 'proxy_pass[[:space:]]+http://127\.0\.0\.1:[0-9]+' "$conf"; then
    app="proxy"; upstream="$(grep -m1 -oE 'http://127\.0\.0\.1:[0-9]+' "$conf")"
  fi

  info "Домен:       $d"
  info "Listen:      $listen (proxy_protocol=$PROXY_PROTOCOL)"
  info "Сертификат:  ${crt:-не найден}"
  if [[ "$app" == "proxy" ]]; then
    info "Контент:     прокси -> $upstream${jitsi_port:+ (Jitsi от selfsteal-jitsi)}"
  else
    info "Контент:     шаблон selfsteal -> будет заменён заглушкой nginx (403)"
  fi
  echo
  warn "Контейнер $OLD_CONTAINER будет остановлен, его файлы останутся в $OLD_DIR (для отката)."
  confirm "Продолжить?" n || return 0

  [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(detect_public_ip || true)"
  save_config

  DOMAIN="$d"; APP="$app"; PAGE="403"; UPSTREAM="$upstream"; ADDED_AT="$(date +%F)"
  if [[ -s "$crt" && -s "$key" ]]; then
    CERT_SOURCE="acme"   # will be re-issued by our acme.sh below
    install -d -m 700 "$NGINX_SSL/$d"
    install -m 644 "$crt" "$(cert_path "$d")"
    install -m 600 "$key" "$(cert_key_path "$d")"
  else
    CERT_SOURCE="acme"
  fi
  save_domain

  render_all
  local out
  out="$(nginx_test)" || { printf '%s\n' "$out" >&2; die "nginx -t не прошёл — $OLD_CONTAINER не тронут."; }

  info "Останавливаю $OLD_CONTAINER..."
  (cd "$OLD_DIR" && docker compose down) >/dev/null 2>&1 || docker rm -f "$OLD_CONTAINER" >/dev/null 2>&1 || true
  nginx_up

  _adopt_disable_old_cron

  info "Перевыпускаю сертификат собственным acme.sh (чтобы продление было нашим)..."
  if issue_cert "$d" force; then
    apply_config
  else
    warn "Перевыпуск не удался — работает старый сертификат ($(cert_summary "$d")). Повторите: selfsteal-apps cert reissue $d"
  fi

  install_cli_hint_after_adopt
  log "Готово. Откат: selfsteal-apps down && (cd $OLD_DIR && docker compose up -d)"
}

# The old renew wrapper adds iptables 443 REDIRECT rules during renewal — must not keep running.
_adopt_disable_old_cron() {
  have crontab || return 0
  local cur; cur="$(crontab -l 2>/dev/null || true)"
  grep -q "$OLD_DIR/acme-renew.sh" <<<"$cur" || return 0
  printf '%s\n' "$cur" > "$CONF_DIR/crontab.bak.$(ts)"
  printf '%s\n' "$cur" | sed "s|^\([^#].*$OLD_DIR/acme-renew.sh.*\)$|# disabled by selfsteal-apps: \1|" | crontab -
  log "Старое задание продления ($OLD_DIR/acme-renew.sh) в cron отключено."
}

install_cli_hint_after_adopt() {
  [[ -f "$OLD_JITSI_STATE" ]] || return 0
  info "Jitsi (selfsteal-jitsi) продолжает работать как есть; домен проксируется на него."
}
