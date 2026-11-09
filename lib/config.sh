# shellcheck shell=bash
# Paths and persistent state.
#
#   /etc/selfsteal-apps/config.env         global settings
#   /etc/selfsteal-apps/domains/<fqdn>.env one file per domain
#   /etc/selfsteal-apps/acme/              acme.sh home (isolated from ~/.acme.sh)
#   /opt/selfsteal-apps/nginx/             docker-compose, nginx.conf, conf.d, ssl, webroot

CONF_DIR="${SSA_CONF_DIR:-/etc/selfsteal-apps}"
CONFIG_FILE="$CONF_DIR/config.env"
DOMAINS_DIR="$CONF_DIR/domains"
ACME_HOME="${SSA_ACME_HOME:-$CONF_DIR/acme}"

DATA_DIR="${SSA_DATA_DIR:-/opt/selfsteal-apps}"
NGINX_DIR="$DATA_DIR/nginx"
NGINX_CONFD="$NGINX_DIR/conf.d"
NGINX_SITES="$NGINX_CONFD/sites"
NGINX_SSL="$NGINX_DIR/ssl"
ACME_WEBROOT="$NGINX_DIR/acme-webroot"

# Defaults (overridden by config.env)
LISTEN_MODE="socket"            # socket | tcp
SOCKET_PATH="/dev/shm/nginx.sock"
TCP_PORT="9443"                 # used when LISTEN_MODE=tcp (127.0.0.1:TCP_PORT)
PUBLIC_PORT="443"               # public Reality port, used for http->https redirects
PROXY_PROTOCOL="1"              # Xray "xver": 1
NGINX_IMAGE="nginx:stable-alpine"
CONTAINER="selfsteal-nginx"
ACME_EMAIL=""
PUBLIC_IP=""

CONFIG_KEYS=(LISTEN_MODE SOCKET_PATH TCP_PORT PUBLIC_PORT PROXY_PROTOCOL NGINX_IMAGE CONTAINER ACME_EMAIL PUBLIC_IP)
DOMAIN_KEYS=(DOMAIN APP PAGE UPSTREAM CERT_SOURCE ADDED_AT)

is_installed() { [[ -f "$CONFIG_FILE" && -f "$NGINX_DIR/docker-compose.yml" ]]; }

load_config() {
  # shellcheck disable=SC1090
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
  return 0
}

_write_env() {
  local file="$1"; shift
  local tmp="${file}.tmp.$$" k
  {
    printf '# Managed by selfsteal-apps. Edit via the CLI where possible.\n'
    for k in "$@"; do printf '%s=%q\n' "$k" "${!k-}"; done
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

save_config() {
  install -d -m 700 "$CONF_DIR" "$DOMAINS_DIR"
  _write_env "$CONFIG_FILE" "${CONFIG_KEYS[@]}"
}

# Domain record: loads into DOMAIN APP PAGE UPSTREAM CERT_SOURCE ADDED_AT
domain_file() { printf '%s/%s.env' "$DOMAINS_DIR" "$1"; }
domain_exists() { [[ -f "$(domain_file "$1")" ]]; }

load_domain() {
  local f; f="$(domain_file "$1")"
  [[ -f "$f" ]] || return 1
  DOMAIN=""; APP="stub"; PAGE="403"; UPSTREAM=""; CERT_SOURCE=""; ADDED_AT=""
  # shellcheck disable=SC1090
  source "$f"
}

save_domain() {
  install -d -m 700 "$DOMAINS_DIR"
  _write_env "$(domain_file "$DOMAIN")" "${DOMAIN_KEYS[@]}"
}

list_domains() {
  local f
  shopt -s nullglob
  for f in "$DOMAINS_DIR"/*.env; do basename "$f" .env; done
  shopt -u nullglob
}

nginx_listen_addr() {
  if [[ "$LISTEN_MODE" == "tcp" ]]; then
    printf '127.0.0.1:%s' "$TCP_PORT"
  else
    printf 'unix:%s' "$SOCKET_PATH"
  fi
}

xray_target() {
  if [[ "$LISTEN_MODE" == "tcp" ]]; then
    printf '127.0.0.1:%s' "$TCP_PORT"
  else
    printf '%s' "$SOCKET_PATH"
  fi
}
