# shellcheck shell=bash
# nginx frontend: renders configs, runs the container.
#
# Traffic path (default):
#   TCP/443 -> Xray Reality -> (not a VPN client) -> unix:/dev/shm/nginx.sock
#           [proxy_protocol, xver 1] -> nginx, TLS with the real cert -> site
#   TCP/80  -> nginx: ACME http-01 + redirect to https
#
# Unknown SNI / bare IP on the TLS listener -> handshake rejected (ssl_reject_handshake),
# like many real servers do; or, with IP access on, the site of IP_DOMAIN.

COMPOSE_PROJECT="selfsteal-apps"

compose() { docker compose -p "$COMPOSE_PROJECT" -f "$NGINX_DIR/docker-compose.yml" "$@"; }

container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == "true" ]]; }

ensure_docker() {
  if ! have docker; then
    warn "Docker не установлен."
    confirm "Установить Docker через get.docker.com?" y || die "Docker обязателен."
    curl -fsSL https://get.docker.com | sh || die "Не удалось установить Docker."
  fi
  docker compose version >/dev/null 2>&1 || die "Нужен Docker Compose v2 (плагин 'docker compose')."
  docker info >/dev/null 2>&1 || die "Docker daemon недоступен."
}

render_compose() {
  local shm=""
  [[ "$LISTEN_MODE" == "socket" ]] && shm="      - /dev/shm:/dev/shm"
  cat > "$NGINX_DIR/docker-compose.yml" <<EOF
# Managed by selfsteal-apps — regenerated on every apply.
services:
  nginx:
    image: ${NGINX_IMAGE}
    container_name: ${CONTAINER}
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./ssl:/etc/nginx/ssl:ro
      - ./acme-webroot:/var/www/acme:ro
${shm}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

render_main_conf() {
  cat > "$NGINX_DIR/nginx.conf" <<'EOF'
# Managed by selfsteal-apps — regenerated on every apply.
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /var/run/nginx.pid;
error_log /dev/stderr warn;

events {
    worker_connections 4096;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - [$time_local] "$host" "$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" rt=$request_time';
    access_log /dev/stdout main;

    server_tokens off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 16m;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_types text/plain text/css text/xml text/javascript application/json
               application/javascript application/xml application/rss+xml image/svg+xml;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/conf.d/sites/*.conf;
}
EOF
}

# Parameters for every TLS "listen" line.
_tls_listen_params() {
  local p="ssl"
  [[ "$PROXY_PROTOCOL" == "1" ]] && p+=" proxy_protocol"
  printf '%s' "$p"
}

_realip_block() {
  [[ "$PROXY_PROTOCOL" == "1" ]] || return 0
  if [[ "$LISTEN_MODE" == "tcp" ]]; then
    printf '    set_real_ip_from 127.0.0.1;\n'
  else
    printf '    set_real_ip_from unix:;\n'
  fi
  printf '    real_ip_header proxy_protocol;\n'
}

render_default_conf() {
  cat > "$NGINX_CONFD/00-default.conf" <<EOF
# Managed by selfsteal-apps — regenerated on every apply.

# Plain HTTP catch-all: serves ACME http-01 for any host (lets a new domain
# get its first certificate before it has its own server block).
server {
    listen 80 default_server;
    server_name _;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF
  # One TLS catch-all per listener (public port): unknown SNI / bare IP -> reject,
  # or the IP-access site on its own port.
  local p ips="" listen
  ips="$(ip_access_site || true)"
  for p in $(site_ports); do
    listen="$(port_listen "$p")"
    if [[ -n "$ips" && "$(site_port "$ips")" == "$p" ]]; then
      # subshell: load_site sets globals used by site_locations
      ( _ip_default_server "$ips" "$listen" ) >> "$NGINX_CONFD/00-default.conf"
    else
      cat >> "$NGINX_CONFD/00-default.conf" <<EOF

# Public port ${p}: TLS catch-all for unknown SNI / bare IP — reject the handshake.
server {
    listen ${listen} $(_tls_listen_params) default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF
    fi
  done
}

# ip_access_site — prints the site (domain@port) shown on https://<IP>:<port>;
# fails if IP access is off or no site has a certificate.
ip_access_site() {
  [[ "${IP_ACCESS:-0}" == "1" ]] || return 1
  local s
  for s in "${IP_DOMAIN:-}" $(list_sites); do
    [[ -n "$s" ]] && site_exists "$s" && has_cert "$(site_domain "$s")" && { printf '%s' "$s"; return 0; }
  done
  return 1
}
# compat: domain shown on IP access
ip_access_domain() { local s; s="$(ip_access_site)" || return 1; site_domain "$s"; }

# TLS catch-all serving site S. Host is pinned to its domain for the upstream:
# apps (Nextcloud trusted_domains, Jitsi) answer only to their own name.
_ip_default_server() {
  local sid="$1" listen="$2" d cn locs
  load_site "$sid" || return 1
  d="$DOMAIN"
  cn="$(domain_cert_name "$d")"
  locs="$(site_locations | sed "s/\\\$host/$d/g")"
  cat <<EOF

# Public port ${PORT}: TLS catch-all for unknown SNI / bare IP — site of ${d} (IP access is on).
server {
    listen ${listen} $(_tls_listen_params) default_server;
    http2 on;
    server_name _;

    ssl_certificate     /etc/nginx/ssl/${cn}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${cn}/privkey.pem;

$(_realip_block)
${locs}
}
EOF
}

# --- site bodies ----------------------------------------------------------

_stub_locations() {
  case "$PAGE" in
    welcome)
      cat <<'EOF'
    root /usr/share/nginx/html;
    index index.html;
    location / {
        try_files $uri $uri/ =404;
    }
EOF
      ;;
    403|404|502|503)
      printf '    location / {\n        return %s;\n    }\n' "$PAGE"
      ;;
    *)
      printf '    location / {\n        return 403;\n    }\n'
      ;;
  esac
}

_proxy_locations() {
  cat <<EOF
    location / {
        proxy_pass ${UPSTREAM};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
EOF
}

# App plugins (apps/<name>/app.sh) define <name>_nginx_locations (uses DOMAIN/UPSTREAM).
site_locations() {
  case "$APP" in
    stub)  _stub_locations ;;
    proxy) _proxy_locations ;;
    *)
      if declare -F "${APP}_nginx_locations" >/dev/null; then
        "${APP}_nginx_locations"
      else
        warn "Неизвестное приложение '$APP' для $DOMAIN — отдаю 403."
        printf '    location / {\n        return 403;\n    }\n'
      fi
      ;;
  esac
}

# One file per domain: an HTTP block (ACME + redirect to the main site) and a TLS block
# for every site (public port) of the domain on that port's listener.
render_site() {
  local d="$1" out main_port cn sid sites
  sites="$(sites_of "$d")"
  [[ -n "$sites" ]] || return 1
  out="$NGINX_SITES/$d.conf"
  main_port="$(site_port "$(domain_main_site "$d")")"
  cn="$(domain_cert_name "$d")"

  {
    printf '# Managed by selfsteal-apps — domain %s, ports: %s\n' "$d" "$(cut -d@ -f2 <<<"$sites" | paste -sd' ' -)"
    cat <<EOF
server {
    listen 80;
    server_name ${d};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 $(public_url "\$host" "$main_port")\$request_uri;
    }
}
EOF
    for sid in $sites; do
      load_site "$sid" || continue
      if store_has "$cn"; then
        cat <<EOF

# ${d} on public port ${PORT} (app: ${APP})
server {
    listen $(port_listen "$PORT") $(_tls_listen_params);
    http2 on;
    server_name ${d};

    ssl_certificate     /etc/nginx/ssl/${cn}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${cn}/privkey.pem;

$(_realip_block)
$(site_locations)
}
EOF
      else
        printf '\n# %s on public port %s: TLS block is disabled — no certificate yet\n' "$d" "$PORT"
      fi
    done
  } > "$out"
}

render_all() {
  install -d -m 755 "$NGINX_DIR" "$NGINX_CONFD" "$NGINX_SITES" "$ACME_WEBROOT/.well-known/acme-challenge"
  install -d -m 700 "$NGINX_SSL"
  render_compose
  render_main_conf
  render_default_conf
  # drop configs of removed domains
  local f d
  shopt -s nullglob
  for f in "$NGINX_SITES"/*.conf; do
    d="$(basename "$f" .conf)"
    domain_exists "$d" || rm -f "$f"
  done
  shopt -u nullglob
  # subshell: render_site loads each domain into globals — keep the caller's DOMAIN/APP/... intact
  for d in $(list_domains); do ( render_site "$d" ); done
}

# _SSA_TEST_IMAGE=1: test with the image on disk (e.g. freshly pulled), not the running container.
nginx_test() {
  if container_running && [[ "${_SSA_TEST_IMAGE:-0}" != "1" ]]; then
    docker exec "$CONTAINER" nginx -t 2>&1
  else
    local shm=()
    [[ "$LISTEN_MODE" == "socket" ]] && shm=(-v "$(mktemp -d):$(dirname "$SOCKET_PATH")")
    docker run --rm --network none \
      -v "$NGINX_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
      -v "$NGINX_CONFD:/etc/nginx/conf.d:ro" \
      -v "$NGINX_SSL:/etc/nginx/ssl:ro" \
      -v "$ACME_WEBROOT:/var/www/acme:ro" \
      "${shm[@]}" "$NGINX_IMAGE" nginx -t 2>&1
  fi
}

# Render + validate + (re)start/reload. Rolls back conf on failure.
apply_config() {
  local backup; backup="$(mktemp -d)"
  [[ -d "$NGINX_DIR" ]] && cp -a "$NGINX_DIR/." "$backup/" 2>/dev/null || true

  render_all

  local out
  if ! out="$(nginx_test)"; then
    err "nginx -t не прошёл:"
    printf '%s\n' "$out" >&2
    warn "Возвращаю предыдущую конфигурацию."
    rm -rf "${NGINX_CONFD:?}" && cp -a "$backup/." "$NGINX_DIR/" 2>/dev/null || true
    rm -rf "$backup"
    return 1
  fi
  # the container itself must be recreated only when its compose definition changed
  local compose_changed=0
  cmp -s "$backup/docker-compose.yml" "$NGINX_DIR/docker-compose.yml" || compose_changed=1
  rm -rf "$backup"

  if container_running && [[ "${_SSA_RECREATE:-0}" != "1" ]] && (( ! compose_changed )); then
    _drop_stale_sockets
    if nginx_hup; then
      _wait_listeners 5 || warn "nginx не открыл часть слушателей — смотрите: selfsteal-apps logs"
      log "Конфиг nginx перечитан (без перезапуска, соединения не рвутся)."
    else
      warn "Не удалось послать reload nginx — перезапускаю контейнер."
      nginx_up
    fi
  else
    nginx_up
  fi
}

# Socket listening right now? (ss sees the nginx container: it runs with network_mode host)
_sock_listening() { ss -Hxl 2>/dev/null | grep -qF " $1 "; }

# A socket file nobody listens on (crash, removed port) makes nginx fail to bind it on reload.
_drop_stale_sockets() {
  local s
  while read -r s; do
    [[ -n "$s" && -S "$s" ]] || continue
    _sock_listening "$s" || rm -f "$s"
  done < <(socket_paths)
  return 0
}

# Wait until every socket listener exists (socket mode). _wait_listeners SECONDS
_wait_listeners() {
  [[ "$LISTEN_MODE" == "socket" ]] || return 0
  local t="${1:-10}" i s missing=""
  for i in $(seq 1 "$t"); do
    missing=""
    while read -r s; do [[ -n "$s" && ! -S "$s" ]] && missing+="$s "; done < <(socket_paths)
    [[ -z "$missing" ]] && return 0
    sleep 1
  done
  warn "Не появились сокеты: $missing"
  return 1
}

nginx_up() {
  container_running || _drop_stale_sockets   # stale sockets after a crash
  compose --progress quiet up -d --force-recreate --remove-orphans >/dev/null
  local i
  for i in $(seq 1 15); do
    container_running && break
    sleep 1
  done
  container_running || { compose logs --tail 30 >&2 || true; die "Контейнер $CONTAINER не запустился."; }
  _wait_listeners 10 || warn "Проверьте логи: selfsteal-apps logs"
  log "nginx запущен ($CONTAINER)."
}

# Reload = SIGHUP to the master (PID 1) from the host via docker. 'docker exec nginx -s reload'
# fails on some hosts with "kill(1, 1) failed (13: Permission denied)" (AppArmor), so never use it.
NGINX_RELOAD_CMD="docker kill -s HUP $CONTAINER"
nginx_hup() { docker kill -s HUP "$CONTAINER" >/dev/null 2>&1; }

nginx_reload() {
  container_running || { nginx_up; return; }
  docker exec "$CONTAINER" nginx -t >/dev/null 2>&1 || { docker exec "$CONTAINER" nginx -t; die "nginx -t не прошёл."; }
  nginx_hup || { warn "reload не прошёл — перезапускаю контейнер."; nginx_up; }
}

# Ensures nothing else holds :80 (and the TCP listen port in tcp mode).
check_ports_free() {
  local p owner
  local tcp=""
  [[ "$LISTEN_MODE" == "tcp" ]] && tcp="$(for p in $(site_ports); do port_target "$p" | cut -d: -f2; done)"
  for p in 80 $tcp; do
    if port_in_use_tcp "$p"; then
      container_running && continue
      owner="$(port_owner_tcp "$p")"
      die "Порт $p уже занят ${owner:-другим процессом}. Освободите его (или используйте 'adopt' для nginx-selfsteal)."
    fi
  done
}
