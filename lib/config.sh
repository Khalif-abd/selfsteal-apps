# shellcheck shell=bash
# Paths and persistent state.
#
#   /etc/selfsteal-apps/config.env         global settings
#   /etc/selfsteal-apps/domains/<fqdn>@<port>.env  one file per site (domain + public port)
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
IP_ACCESS="0"                   # 1 = https://<IP> and unknown SNI show IP_DOMAIN's site; 0 = reject handshake
IP_DOMAIN=""                    # domain shown on IP access (empty/removed -> first domain with a cert)
UI_EMOJI="1"                    # 1 = emoji icons in the menu; 0 = plain text (for terminals that draw them badly)
TCP_PORTS=""                    # tcp mode: local nginx ports of extra public ports, "444:9444 8443:9445"

CONFIG_KEYS=(LISTEN_MODE SOCKET_PATH TCP_PORT PUBLIC_PORT PROXY_PROTOCOL NGINX_IMAGE CONTAINER ACME_EMAIL PUBLIC_IP IP_ACCESS IP_DOMAIN UI_EMOJI TCP_PORTS)
DOMAIN_KEYS=(DOMAIN PORT APP PAGE UPSTREAM CERT_SOURCE ADDED_AT)

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

# --- sites -------------------------------------------------------------------
# A site = domain + public port (the port of the Xray inbound the client connects to).
# Each public port has its own nginx listener (socket / local tcp port), so the same
# domain can serve different things on different ports. Certificates belong to the domain.
#
# Site id: "<fqdn>@<port>". Record keys: DOMAIN PORT APP PAGE UPSTREAM CERT_SOURCE ADDED_AT.

site_id()     { printf '%s@%s' "$1" "${2:-$PUBLIC_PORT}"; }
site_domain() { printf '%s' "${1%@*}"; }
site_port()   { printf '%s' "${1##*@}"; }
site_file()   { printf '%s/%s.env' "$DOMAINS_DIR" "$1"; }
site_exists() { [[ "$1" == *@* && -f "$(site_file "$1")" ]]; }
# "meet.x" on 443, "meet.x:444" otherwise — what users type in a browser.
site_label()  { local p; p="$(site_port "$1")"; printf '%s%s' "$(site_domain "$1")" "$([[ "$p" != 443 ]] && echo ":$p")"; }
public_url()  { printf 'https://%s%s' "$1" "$([[ "${2:-443}" != 443 ]] && echo ":$2")"; }

load_site() {
  local f; f="$(site_file "$1")"
  [[ "$1" == *@* && -f "$f" ]] || return 1
  DOMAIN=""; PORT=""; APP="stub"; PAGE="403"; UPSTREAM=""; CERT_SOURCE=""; ADDED_AT=""
  # shellcheck disable=SC1090
  source "$f"
  DOMAIN="${DOMAIN:-$(site_domain "$1")}"; PORT="${PORT:-$(site_port "$1")}"
}

save_site() {
  [[ -n "$DOMAIN" && -n "$PORT" ]] || die "save_site: нет DOMAIN/PORT."
  install -d -m 700 "$DOMAINS_DIR"
  _write_env "$(site_file "$(site_id "$DOMAIN" "$PORT")")" "${DOMAIN_KEYS[@]}"
}

# All site ids, sorted by domain then numerically by port.
list_sites() {
  local f
  shopt -s nullglob
  for f in "$DOMAINS_DIR"/*@*.env; do basename "$f" .env; done | sort -t@ -k1,1 -k2,2n
  shopt -u nullglob
}

sites_of() { list_sites | awk -v d="$1" -F@ '$1 == d'; }

# Unique domains (certificates, DNS and the menu work per domain).
list_domains() { list_sites | cut -d@ -f1 | uniq; }
domain_exists() { [[ -n "$1" && -n "$(sites_of "$1")" ]]; }

# Main site of a domain: the one on PUBLIC_PORT, else the lowest port.
domain_main_site() {
  local s; s="$(sites_of "$1")"
  [[ -n "$s" ]] || return 1
  grep -Fx "$(site_id "$1" "$PUBLIC_PORT")" <<<"$s" || head -1 <<<"$s"
}

# Domain-level view (cert source etc.): loads the main site.
load_domain() { local s; s="$(domain_main_site "$1")" || return 1; load_site "$s"; }
save_domain() { save_site; }

# Public ports in use: PUBLIC_PORT (main listener, always) + ports of all sites.
site_ports() { { printf '%s\n' "$PUBLIC_PORT"; list_sites | cut -d@ -f2; } | sort -un; }

valid_public_port() { valid_port "$1" && [[ "$1" != 80 ]]; }

# --- listeners -----------------------------------------------------------------
# PUBLIC_PORT -> SOCKET_PATH / 127.0.0.1:TCP_PORT (as before); any other public port P ->
# <socket dir>/nginx-P.sock, or a local tcp port from TCP_PORTS.

_tcp_local_port() { local m; for m in $TCP_PORTS; do [[ "${m%%:*}" == "$1" ]] && { printf '%s' "${m#*:}"; return 0; }; done; return 1; }

# tcp mode: make sure public port P has a local nginx port (saved in config).
ensure_port_listener() {
  local p="$1" l used
  [[ "$LISTEN_MODE" == tcp && "$p" != "$PUBLIC_PORT" ]] || return 0
  _tcp_local_port "$p" >/dev/null && return 0
  local m; used=" $TCP_PORT "; for m in $TCP_PORTS; do used+="${m#*:} "; done
  for l in $(seq $((TCP_PORT + 1)) $((TCP_PORT + 200))); do
    (( l <= 65535 )) || break
    [[ "$used" == *" $l "* ]] && continue
    port_in_use_tcp "$l" && continue
    TCP_PORTS="${TCP_PORTS:+$TCP_PORTS }$p:$l"; save_config
    return 0
  done
  die "Не нашёл свободный локальный порт для публичного порта $p."
}

# Xray "target" for public port P (no "unix:" prefix).
port_target() {
  local p="${1:-$PUBLIC_PORT}"
  if [[ "$LISTEN_MODE" == tcp ]]; then
    if [[ "$p" == "$PUBLIC_PORT" ]]; then printf '127.0.0.1:%s' "$TCP_PORT"
    else printf '127.0.0.1:%s' "$(_tcp_local_port "$p" || echo '?')"; fi
  else
    if [[ "$p" == "$PUBLIC_PORT" ]]; then printf '%s' "$SOCKET_PATH"
    else printf '%s/nginx-%s.sock' "$(dirname "$SOCKET_PATH")" "$p"; fi
  fi
}

# nginx "listen" address for public port P.
port_listen() {
  if [[ "$LISTEN_MODE" == tcp ]]; then port_target "$1"; else printf 'unix:%s' "$(port_target "$1")"; fi
}

nginx_listen_addr() { port_listen "$PUBLIC_PORT"; }
xray_target()       { port_target "$PUBLIC_PORT"; }

# Socket paths of all listeners (socket mode).
socket_paths() { [[ "$LISTEN_MODE" == socket ]] || return 0; local p; for p in $(site_ports); do port_target "$p"; echo; done; }

# <=0.6: domains/<fqdn>.env, one per domain, implicitly on PUBLIC_PORT -> <fqdn>@<PUBLIC_PORT>.env.
migrate_sites() {
  [[ -d "$DOMAINS_DIR" ]] || return 0
  local f d
  shopt -s nullglob
  for f in "$DOMAINS_DIR"/*.env; do
    d="$(basename "$f" .env)"
    [[ "$d" == *@* ]] && continue
    (
      load_site_legacy() { DOMAIN=""; PORT=""; APP="stub"; PAGE="403"; UPSTREAM=""; CERT_SOURCE=""; ADDED_AT=""; source "$1"; }
      load_site_legacy "$f"
      DOMAIN="${DOMAIN:-$d}"; PORT="${PORT:-$PUBLIC_PORT}"
      save_site
    ) && rm -f "$f"
  done
  shopt -u nullglob
  if [[ -n "${IP_DOMAIN:-}" && "$IP_DOMAIN" != *@* ]]; then IP_DOMAIN="$(site_id "$IP_DOMAIN" "$PUBLIC_PORT")"; save_config; fi
  return 0
}
