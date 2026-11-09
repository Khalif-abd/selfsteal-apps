# shellcheck shell=bash
# nginx frontend: renders configs, runs the container.
#
# Traffic path (default):
#   TCP/443 -> Xray Reality -> (not a VPN client) -> unix:/dev/shm/nginx.sock
#           [proxy_protocol, xver 1] -> nginx, TLS with the real cert -> site
#   TCP/80  -> nginx: ACME http-01 + redirect to https
#
# Unknown SNI on the TLS listener -> handshake rejected (ssl_reject_handshake),
# like many real servers do.

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
  local listen; listen="$(nginx_listen_addr)"
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

# TLS catch-all for unknown SNI: reject the handshake.
server {
    listen ${listen} $(_tls_listen_params) default_server;
    server_name _;
    ssl_reject_handshake on;
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

render_site() {
  local d="$1" out listen redirect_port="" cn
  load_domain "$d" || return 1
  out="$NGINX_SITES/$d.conf"
  listen="$(nginx_listen_addr)"
  [[ "$PUBLIC_PORT" != "443" ]] && redirect_port=":$PUBLIC_PORT"

  {
    printf '# Managed by selfsteal-apps — domain %s (app: %s)\n' "$d" "$APP"
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
        return 301 https://\$host${redirect_port}\$request_uri;
    }
}
EOF
    cn="$(domain_cert_name "$d")"
    if store_has "$cn"; then
      cat <<EOF

server {
    listen ${listen} $(_tls_listen_params);
    http2 on;
    server_name ${d};

    ssl_certificate     /etc/nginx/ssl/${cn}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${cn}/privkey.pem;

$(_realip_block)
$(site_locations)
}
EOF
    else
      printf '\n# TLS block is disabled: no certificate yet for %s\n' "$d"
    fi
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

nginx_test() {
  if container_running; then
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
  rm -rf "$backup"

  if container_running && [[ "${_SSA_RECREATE:-0}" != "1" ]]; then
    docker exec "$CONTAINER" nginx -s reload >/dev/null 2>&1
    log "nginx перезагружен."
  else
    nginx_up
  fi
}

nginx_up() {
  if ! container_running && [[ "$LISTEN_MODE" == "socket" && -S "$SOCKET_PATH" ]]; then
    rm -f "$SOCKET_PATH"   # stale socket after crash
  fi
  compose --progress quiet up -d --force-recreate --remove-orphans >/dev/null
  local i
  for i in $(seq 1 15); do
    container_running && break
    sleep 1
  done
  container_running || { compose logs --tail 30 >&2 || true; die "Контейнер $CONTAINER не запустился."; }
  if [[ "$LISTEN_MODE" == "socket" ]]; then
    for i in $(seq 1 10); do [[ -S "$SOCKET_PATH" ]] && break; sleep 1; done
    [[ -S "$SOCKET_PATH" ]] || warn "Сокет $SOCKET_PATH не появился — проверьте логи."
  fi
  log "nginx запущен ($CONTAINER)."
}

nginx_reload() {
  container_running || { nginx_up; return; }
  docker exec "$CONTAINER" nginx -t >/dev/null 2>&1 || { docker exec "$CONTAINER" nginx -t; die "nginx -t не прошёл."; }
  docker exec "$CONTAINER" nginx -s reload >/dev/null 2>&1
}

# Ensures nothing else holds :80 (and the TCP listen port in tcp mode).
check_ports_free() {
  local p owner
  for p in 80 $([[ "$LISTEN_MODE" == "tcp" ]] && echo "$TCP_PORT"); do
    if port_in_use_tcp "$p"; then
      container_running && continue
      owner="$(port_owner_tcp "$p")"
      die "Порт $p уже занят ${owner:-другим процессом}. Освободите его (или используйте 'adopt' для nginx-selfsteal)."
    fi
  done
}
