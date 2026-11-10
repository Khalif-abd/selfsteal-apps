# shellcheck shell=bash
# Certificates.
#
# Store: $NGINX_SSL/<name>/{fullchain.pem,privkey.pem}
#   <name> = "meet.example.com"   certificate for one host (http-01 or imported)
#   <name> = "star.example.com"   wildcard: *.example.com + example.com
#
# A domain uses, in this order: its own certificate (unless CERT_SOURCE=wildcard),
# then a wildcard that covers it. So copying a store folder (e.g. star.example.com)
# to another node and running "selfsteal-apps restart" is enough for it to be used.
#
# Issuance: acme.sh in its own home ($ACME_HOME), never touching ~/.acme.sh.
#   single host -> http-01 via our nginx on :80
#   wildcard    -> dns-01 via Cloudflare API (token scoped to the zone)

ACME_BIN="$ACME_HOME/acme.sh"
ACME_SERVER="${ACME_SERVER:-letsencrypt}"
CF_DIR="$CONF_DIR/cloudflare"
CF_API="https://api.cloudflare.com/client/v4"

acme() { "$ACME_BIN" --home "$ACME_HOME" --config-home "$ACME_HOME/data" "$@"; }
acme_installed() { [[ -x "$ACME_BIN" ]]; }

# --- store ----------------------------------------------------------------

store_dir()     { printf '%s/%s' "$NGINX_SSL" "$1"; }
cert_path()     { printf '%s/%s/fullchain.pem' "$NGINX_SSL" "$1"; }
cert_key_path() { printf '%s/%s/privkey.pem' "$NGINX_SSL" "$1"; }
store_has()     { [[ -n "$1" && -s "$(cert_path "$1")" && -s "$(cert_key_path "$1")" ]]; }

store_names() {
  local d
  shopt -s nullglob
  for d in "$NGINX_SSL"/*/; do d="${d%/}"; store_has "$(basename "$d")" && basename "$d"; done
  shopt -u nullglob
}

wildcard_name() { printf 'star.%s' "$1"; }
is_wildcard_name() { [[ "$1" == star.* ]]; }

# Field of a domain record without touching the caller's globals.
_domain_field() { ( load_domain "$1" >/dev/null 2>&1 && printf '%s' "${!2-}" ); }

# Store name serving DOMAIN (may not exist yet -> own name).
domain_cert_name() {
  local d="$1" src parent
  src="$(_domain_field "$d" CERT_SOURCE)"
  if [[ "$src" != "wildcard" ]] && store_has "$d"; then printf '%s' "$d"; return; fi
  parent="${d#*.}"
  if [[ "$parent" == *.* ]] && store_has "$(wildcard_name "$parent")" && cert_covers "$(wildcard_name "$parent")" "$d"; then
    wildcard_name "$parent"; return
  fi
  if store_has "$(wildcard_name "$d")"; then wildcard_name "$d"; return; fi   # apex of a wildcard
  printf '%s' "$d"
}

has_cert() { store_has "$(domain_cert_name "$1")"; }

# Wildcard covering DOMAIN, if any (prints store name).
covering_wildcard() {
  local n; n="$(domain_cert_name "$1")"
  is_wildcard_name "$n" && store_has "$n" && printf '%s' "$n"
}

cert_sans() {
  [[ -s "$1" ]] || return 0
  { openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null |
      grep -oE 'DNS:[^, ]+' | sed 's/^DNS://' | tr '[:upper:]' '[:lower:]'; } || true
}

# cert_covers STORE_NAME HOST
cert_covers() {
  local san h="$2"
  while read -r san; do
    [[ "$san" == "$h" ]] && return 0
    if [[ "$san" == \*.* && "${h#*.}" == "${san#\*.}" && "$h" == *.* ]]; then return 0; fi
  done < <(cert_sans "$(cert_path "$1")")
  return 1
}

_store_days_left() {
  local f; f="$(cert_path "$1")"
  [[ -s "$f" ]] || return 1
  local end end_s
  end="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)" || return 1
  end_s="$(date -d "$end" +%s 2>/dev/null)" || return 1
  echo $(( (end_s - $(date +%s)) / 86400 ))
}
cert_days_left() { _store_days_left "$(domain_cert_name "$1")"; }

_store_issuer() {
  local f issuer
  f="$(cert_path "$1")"
  if [[ "$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject=//')" == \
        "$(openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed 's/^issuer=//')" ]]; then
    echo "self-signed"; return
  fi
  issuer="$(openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed -n 's/.*O *= *\([^,]*\).*/\1/p')"
  [[ -n "$issuer" ]] || issuer="$(openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')"
  printf '%s' "${issuer:-?}"
}

# Auto-renewed by our acme.sh on this node?
store_renewed_here() {
  local n="$1" main
  acme_installed || return 1
  if is_wildcard_name "$n"; then main="*.${n#star.}"; else main="$n"; fi
  [[ -f "$ACME_HOME/data/${main}_ecc/${main}.conf" || -f "$ACME_HOME/certs/${main}_ecc/${main}.conf" ]]
}

store_summary() {
  local n="$1" f days end color="$C_GREEN" how
  f="$(cert_path "$n")"
  if ! store_has "$n"; then printf '%sнет сертификата%s' "$C_RED" "$C_RESET"; return; fi
  end="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)"
  days="$(_store_days_left "$n" || echo '?')"
  [[ "$days" =~ ^-?[0-9]+$ ]] && { (( days < 14 )) && color="$C_YELLOW"; (( days < 0 )) && color="$C_RED"; }
  store_renewed_here "$n" && how="автопродление" || how="${C_YELLOW}без автопродления${C_RESET}"
  printf '%s%s дн.%s (до %s, %s, %s)' "$color" "$days" "$C_RESET" \
    "$(date -d "$end" +%F 2>/dev/null || echo "$end")" "$(_store_issuer "$n")" "$how"
}

cert_summary() {
  local d="$1" n
  n="$(domain_cert_name "$d")"
  store_summary "$n"
  is_wildcard_name "$n" && store_has "$n" && printf ' · wildcard *.%s' "${n#star.}"
  return 0
}

# --- zone helpers -----------------------------------------------------------

# Registrable domain ("zone") of a host: meet.work-mesh.org -> work-mesh.org,
# a.b.example.co.uk -> example.co.uk. Good enough for Cloudflare zones.
registrable_zone() {
  local h="${1#\*.}" IFS=. labels n
  read -r -a labels <<<"$h"
  n=${#labels[@]}
  (( n <= 2 )) && { printf '%s' "$h"; return; }
  local sld="${labels[$((n-2))]}" tld="${labels[$((n-1))]}"
  if (( ${#tld} == 2 )) && [[ "$sld" =~ ^(co|com|net|org|gov|edu|ac|or|ne|go|msk|spb)$ ]]; then
    printf '%s.%s.%s' "${labels[$((n-3))]}" "$sld" "$tld"
  else
    printf '%s.%s' "$sld" "$tld"
  fi
}

# --- acme.sh ------------------------------------------------------------------

ensure_cron() {
  have crontab && return 0
  info "Устанавливаю cron (нужен для автопродления сертификатов)..."
  pkg_install cron || pkg_install cronie || true
  have systemctl && { systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true; }
  have crontab || die "cron не установлен — поставьте его вручную и повторите."
}

ensure_acme() {
  acme_installed && return 0
  ensure_cron
  have git || pkg_install git || die "git обязателен для установки acme.sh."
  info "Устанавливаю acme.sh в $ACME_HOME ..."
  local tmp; tmp="$(mktemp -d)"
  git clone -q --depth 1 https://github.com/acmesh-official/acme.sh.git "$tmp/acme.sh" ||
    { rm -rf "$tmp"; die "Не удалось скачать acme.sh."; }
  local args=(--install --home "$ACME_HOME" --config-home "$ACME_HOME/data")
  [[ -n "$ACME_EMAIL" ]] && args+=(--accountemail "$ACME_EMAIL")
  ( cd "$tmp/acme.sh" && ./acme.sh "${args[@]}" >/dev/null ) ||
    { rm -rf "$tmp"; die "Установка acme.sh не удалась."; }
  rm -rf "$tmp"
  acme --set-default-ca --server "$ACME_SERVER" >/dev/null
  acme --upgrade --auto-upgrade 0 >/dev/null 2>&1 || true
  log "acme.sh установлен, автопродление — через cron (ежедневно)."
}

_acme_selfcheck() {
  local d="$1" token body
  token="ssa-check-$RANDOM$RANDOM"
  printf '%s' "$token" > "$ACME_WEBROOT/.well-known/acme-challenge/$token"
  chmod 644 "$ACME_WEBROOT/.well-known/acme-challenge/$token"
  body="$(curl -fsS --max-time 5 --resolve "$d:80:127.0.0.1" "http://$d/.well-known/acme-challenge/$token" 2>/dev/null || true)"
  rm -f "$ACME_WEBROOT/.well-known/acme-challenge/$token"
  [[ "$body" == "$token" ]]
}

check_dns() {
  local d="$1" ips
  [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(detect_public_ip || true)"
  ips="$(resolve_a "$d")"
  if [[ -z "$ips" ]]; then
    warn "$d не резолвится (нет A-записи)."
    return 1
  fi
  if [[ -n "$PUBLIC_IP" ]] && ! grep -qx "$PUBLIC_IP" <<<"$ips"; then
    warn "$d указывает на $(tr '\n' ' ' <<<"$ips")— а IP сервера $PUBLIC_IP."
    return 1
  fi
  log "DNS: $d -> $PUBLIC_IP"
}

# Copies an issued cert into the store; acme.sh repeats this on every renewal.
_acme_install_cert() {
  local main="$1" name="$2"
  install -d -m 700 "$(store_dir "$name")"
  acme --install-cert -d "$main" --ecc \
    --fullchain-file "$(cert_path "$name")" \
    --key-file "$(cert_key_path "$name")" \
    --reloadcmd "docker exec $CONTAINER nginx -s reload >/dev/null 2>&1" >/dev/null 2>&1 && return 0
  # acme.sh copies the files first and runs reloadcmd last: a failed reload alone is not a failed install
  if store_has "$name"; then
    warn "acme.sh не смог перезагрузить nginx (файлы сертификата на месте) — перезагружу сам."
    return 0
  fi
  return 1
}

# issue_cert DOMAIN [force] — single-host certificate via http-01.
issue_cert() {
  local d="$1" force="${2:-}" rc=0 out
  ensure_acme
  container_running || die "nginx не запущен — сначала 'selfsteal-apps install'."

  if [[ "${SSA_SKIP_DNS_CHECK:-0}" != "1" ]] && ! check_dns "$d"; then
    # never auto-confirm this one: a pointless attempt just burns Let's Encrypt rate limits
    if ! is_interactive || ! confirm "DNS не совпадает. Всё равно пытаться выпустить сертификат?" n; then
      return 1
    fi
  fi
  if ! _acme_selfcheck "$d"; then
    err "nginx не отдаёт /.well-known/acme-challenge/ для $d на :80 локально."
    return 1
  fi

  info "Выпускаю сертификат для $d (Let's Encrypt, http-01)..."
  local args=(--issue -d "$d" -w "$ACME_WEBROOT" --server "$ACME_SERVER" --keylength ec-256)
  [[ "$force" == "force" ]] && args+=(--force)
  out="$(acme "${args[@]}" 2>&1)" || rc=$?
  # rc 2 = cert still valid, nothing to do
  if (( rc != 0 && rc != 2 )); then
    err "acme.sh не смог выпустить сертификат для $d:"
    printf '%s\n' "$out" | tail -n 15 >&2
    warn "Проверьте: A-запись домена, открыт ли TCP/80 снаружи (ufw/security group)."
    return 1
  fi
  _acme_install_cert "$d" "$d" || { err "Не удалось установить сертификат в $(store_dir "$d")."; return 1; }
  log "Сертификат для $d готов."
}

# --- Cloudflare wildcard (dns-01) --------------------------------------------

_cf_file() { printf '%s/%s.env' "$CF_DIR" "$1"; }

_cf_api() {  # _cf_api TOKEN PATH
  curl -fsS --max-time 15 -H "Authorization: Bearer $1" -H "Content-Type: application/json" "$CF_API$2" 2>/dev/null
}

_cf_verify_token() {
  [[ "${SSA_SKIP_CF_VERIFY:-0}" == "1" ]] && return 0
  _cf_api "$1" "/user/tokens/verify" | grep -q '"status":"active"'
}

_cf_lookup_zone_id() {  # TOKEN ZONE -> id (needs Zone:Read; may fail with a DNS-only token)
  _cf_api "$1" "/zones?name=$2" | grep -oE '"id":"[0-9a-f]{32}"' | head -1 | cut -d'"' -f4
}

# Loads/asks Cloudflare credentials for ZONE into CF_TOKEN / CF_ZONE_ID.
cf_credentials() {
  local zone="$1" token_arg="${2:-}" zid_arg="${3:-}" f
  f="$(_cf_file "$zone")"
  CF_TOKEN=""; CF_ZONE_ID=""
  # shellcheck disable=SC1090
  [[ -f "$f" ]] && source "$f"
  [[ -n "$token_arg" ]] && CF_TOKEN="$token_arg"
  [[ -n "$zid_arg" ]] && CF_ZONE_ID="$zid_arg"

  if [[ -z "$CF_TOKEN" ]]; then
    is_interactive || die "Нужен токен Cloudflare: --cf-token (права: Zone → DNS → Edit на зону $zone)."
    info "Токен Cloudflare: My Profile → API Tokens → Create Token → «Edit zone DNS», зона $zone."
    read -r -s -p "$(printf '%s?%s API-токен Cloudflare: ' "$C_CYAN" "$C_RESET")" CF_TOKEN; echo
  fi
  [[ "$CF_TOKEN" =~ ^[A-Za-z0-9_-]{30,}$ ]] || die "Токен Cloudflare выглядит неверно."
  _cf_verify_token "$CF_TOKEN" || die "Cloudflare не принял токен (неактивен, истёк или фильтр по IP)."

  if [[ -z "$CF_ZONE_ID" ]]; then
    CF_ZONE_ID="$(_cf_lookup_zone_id "$CF_TOKEN" "$zone" || true)"
    if [[ -z "$CF_ZONE_ID" ]]; then
      is_interactive || die "Нужен Zone ID: --cf-zone-id (Cloudflare → $zone → Overview, справа внизу)."
      info "Zone ID: Cloudflare → $zone → Overview, справа внизу (32 символа)."
      ask CF_ZONE_ID "Zone ID зоны $zone"
    fi
  fi
  [[ "$CF_ZONE_ID" =~ ^[0-9a-f]{32}$ ]] || die "Zone ID должен быть 32 hex-символа."

  install -d -m 700 "$CF_DIR"
  _write_env "$f" CF_TOKEN CF_ZONE_ID
}

# Resolve user input (zone, subdomain or *.zone) into a zone, confirming when interactive.
pick_zone() {
  local __pz_var="$1" __pz_in="$2" __pz_zone
  __pz_in="$(lower "${__pz_in#\*.}")"
  valid_domain "$__pz_in" || die "Некорректный домен: '$__pz_in'"
  __pz_zone="$(registrable_zone "$__pz_in")"
  if [[ "$__pz_zone" != "$__pz_in" ]] && is_interactive; then
    ask __pz_zone "Зона для wildcard (корневой домен)" "$__pz_zone"
    __pz_zone="$(lower "${__pz_zone#\*.}")"
    valid_domain "$__pz_zone" || die "Некорректная зона: '$__pz_zone'"
  fi
  printf -v "$__pz_var" '%s' "$__pz_zone"
}

# wildcard_issue <zone|subdomain> [--cf-token T] [--cf-zone-id ID] [--force]
wildcard_issue() {
  local input="" token="" zid="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cf-token) token="${2:-}"; shift 2;;
      --cf-zone-id) zid="${2:-}"; shift 2;;
      --force) force=1; shift;;
      -*) die "Неизвестная опция: $1";;
      *) input="$1"; shift;;
    esac
  done
  [[ -n "$input" ]] || ask input "Домен или поддомен зоны (например work-mesh.org)"
  local zone; pick_zone zone "$input"
  local name; name="$(wildcard_name "$zone")"

  if store_has "$name" && ! store_renewed_here "$name" && (( ! force )); then
    warn "Wildcard для $zone уже есть (импортирован): $(store_summary "$name")"
    confirm "Выпустить новый здесь (с автопродлением через Cloudflare)?" n || return 0
  fi

  cf_credentials "$zone" "$token" "$zid"
  ensure_acme

  info "Выпускаю wildcard *.$zone + $zone (Let's Encrypt, dns-01 через Cloudflare)..."
  local args=(--issue --dns "${SSA_DNS_HOOK:-dns_cf}" -d "*.$zone" -d "$zone" --server "$ACME_SERVER" --keylength ec-256)
  (( force )) && args+=(--force)
  # testing hook (e.g. "--dnssleep 2" against a local ACME test server)
  # shellcheck disable=SC2206
  [[ -n "${SSA_ACME_EXTRA:-}" ]] && args+=(${SSA_ACME_EXTRA})
  local out rc=0
  out="$(CF_Token="$CF_TOKEN" CF_Zone_ID="$CF_ZONE_ID" acme "${args[@]}" 2>&1)" || rc=$?
  if (( rc != 0 && rc != 2 )); then
    err "acme.sh не смог выпустить wildcard для $zone:"
    printf '%s\n' "$out" | tail -n 15 >&2
    warn "Проверьте права токена (Zone → DNS → Edit на $zone) и Zone ID."
    return 1
  fi
  _acme_install_cert "*.$zone" "$name" || { err "Не удалось установить сертификат в $(store_dir "$name")."; return 1; }
  log "Wildcard *.$zone готов: $(store_summary "$name")"
  _adopt_wildcard_for_zone "$zone"
}

# Switch domains of ZONE to the wildcard (asks for domains that have their own cert).
_adopt_wildcard_for_zone() {
  local zone="$1" name d n changed=0
  name="$(wildcard_name "$zone")"
  for d in $(list_domains); do
    [[ "$d" == "$zone" || "$d" == *".$zone" ]] || continue
    cert_covers "$name" "$d" || continue
    n="$(domain_cert_name "$d")"
    [[ "$n" == "$name" ]] && { _set_cert_source "$d" wildcard; changed=1; continue; }
    if confirm "$d использует свой сертификат. Переключить на wildcard?" y; then
      _set_cert_source "$d" wildcard
      remove_cert "$d"
      changed=1
    fi
  done
  apply_config
  (( changed )) && log "Домены зоны $zone используют wildcard."
  return 0
}

_set_cert_source() {
  ( load_domain "$1" && CERT_SOURCE="$2" && save_domain )
}

wildcard_remove() {
  local input="${1:-}" zone name
  [[ -n "$input" ]] || ask input "Зона wildcard"
  zone="$(registrable_zone "$(lower "${input#\*.}")")"
  [[ "$input" == star.* ]] && zone="${input#star.}"
  name="$(wildcard_name "$zone")"
  store_has "$name" || die "Wildcard для $zone не найден."
  local users=() d
  for d in $(list_domains); do [[ "$(domain_cert_name "$d")" == "$name" ]] && users+=("$d"); done
  (( ${#users[@]} )) && warn "Его используют: ${users[*]} — у них пропадёт TLS."
  confirm "Удалить wildcard *.$zone?" n || return 0
  if acme_installed; then
    acme --remove -d "*.$zone" --ecc >/dev/null 2>&1 || true
    rm -rf "${ACME_HOME:?}/data/*.${zone}_ecc"
  fi
  rm -rf "$(store_dir "$name")" "$(_cf_file "$zone")"
  for d in "${users[@]}"; do _set_cert_source "$d" acme; done
  apply_config
  log "Wildcard *.$zone удалён."
}

# --- import / export (manual copying between nodes) ----------------------------

# cert_export <domain|zone|store-name> [out.tar.gz]
cert_export() {
  local what="${1:-}" out="${2:-}" n
  if [[ -z "$what" ]]; then
    local names; mapfile -t names < <(store_names)
    (( ${#names[@]} )) || die "Сертификатов нет."
    choose what "Какой сертификат выгрузить?" 1 "${names[@]}"
  fi
  what="$(lower "$what")"
  if store_has "$what"; then n="$what"
  elif domain_exists "$what"; then n="$(domain_cert_name "$what")"
  else n="$(wildcard_name "$(registrable_zone "${what#\*.}")")"
  fi
  store_has "$n" || die "Сертификат '$what' не найден."
  out="${out:-/root/selfsteal-cert-${n}-$(date +%F).tar.gz}"
  ( umask 077; tar -czf "$out" -C "$NGINX_SSL" "$n" ) || die "Не удалось создать $out"
  chmod 600 "$out"
  log "Готово: $out  ($(store_summary "$n"))"
  cat <<EOF

На другую ноду (там уже установлен selfsteal-apps):
  scp $out root@<нода>:/root/
  ssh root@<нода> selfsteal-apps cert import /root/$(basename "$out")

Или вручную: скопировать папку $(store_dir "$n") в такой же путь и выполнить: selfsteal-apps restart
EOF
}

# Pick fullchain/key files in a directory.
_find_pair() {
  local dir="$1" f crt="" key=""
  shopt -s nullglob
  for f in "$dir"/fullchain.pem "$dir"/fullchain.crt "$dir"/fullchain.cer "$dir"/*.crt "$dir"/*.cer "$dir"/cert.pem; do
    [[ -s "$f" ]] && openssl x509 -in "$f" -noout >/dev/null 2>&1 && { crt="$f"; break; }
  done
  for f in "$dir"/privkey.pem "$dir"/private.key "$dir"/*.key "$dir"/key.pem; do
    [[ -s "$f" ]] && { key="$f"; break; }
  done
  shopt -u nullglob
  [[ -n "$crt" && -n "$key" ]] && printf '%s\n%s\n' "$crt" "$key"
}

# cert_import <archive.tar.gz | directory | fullchain.pem privkey.pem>
cert_import() {
  local a="${1:-}" b="${2:-}" tmp="" crt key
  [[ -n "$a" ]] || ask a "Путь к архиву .tar.gz, папке или fullchain.pem"
  [[ -e "$a" ]] || die "Не найдено: $a"
  if [[ -n "$b" ]]; then crt="$a"; key="$b"
  else
    local dir="$a"
    if [[ -f "$a" && "$a" =~ \.(tar\.gz|tgz)$ ]]; then
      tmp="$(mktemp -d)"
      tar -xzf "$a" -C "$tmp" --no-same-owner || { rm -rf "$tmp"; die "Не удалось распаковать $a"; }
      dir="$(dirname "$(find "$tmp" -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) | head -1)")"
    elif [[ -f "$a" ]]; then
      dir="$(dirname "$a")"
    fi
    local pair; pair="$(_find_pair "$dir")" || { [[ -n "$tmp" ]] && rm -rf "$tmp"; die "В $a не нашёл пару сертификат + ключ."; }
    crt="$(sed -n 1p <<<"$pair")"; key="$(sed -n 2p <<<"$pair")"
  fi

  openssl x509 -in "$crt" -noout >/dev/null 2>&1 || die "$crt — не сертификат."
  local cpub kpub
  cpub="$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl sha256)"
  kpub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256)"
  [[ -n "$kpub" && "$cpub" == "$kpub" ]] || { [[ -n "$tmp" ]] && rm -rf "$tmp"; die "Ключ не подходит к сертификату."; }

  local sans name wild="" first
  sans="$(cert_sans "$crt")"
  [[ -n "$sans" ]] || die "В сертификате нет SAN-имён."
  wild="$(grep -m1 '^\*\.' <<<"$sans" || true)"
  first="$(head -1 <<<"$sans")"
  if [[ -n "$wild" ]]; then name="$(wildcard_name "${wild#\*.}")"; else name="$first"; fi
  valid_domain "${name#star.}" || die "Странное имя в сертификате: $name"

  if store_has "$name" && store_renewed_here "$name"; then
    warn "$name уже выпускается и продлевается на этой ноде — импорт его заменит до следующего продления."
    confirm "Продолжить?" n || { [[ -n "$tmp" ]] && rm -rf "$tmp"; return 0; }
  fi
  install -d -m 700 "$(store_dir "$name")"
  install -m 644 "$crt" "$(cert_path "$name")"
  install -m 600 "$key" "$(cert_key_path "$name")"
  [[ -n "$tmp" ]] && rm -rf "$tmp"
  log "Импортирован: $name — $(tr '\n' ' ' <<<"$sans")"
  info "$(store_summary "$name")"

  if [[ -n "$wild" ]]; then
    _adopt_wildcard_for_zone "${wild#\*.}"
  else
    local d
    while read -r d; do
      domain_exists "$d" && _set_cert_source "$d" manual
    done <<<"$sans"
    apply_config
  fi
  local d
  for d in $(list_domains); do
    [[ "$(domain_cert_name "$d")" == "$name" ]] && info "  используется: $d"
  done
  return 0
}

# Old entry point: cert manual <domain> <crt> <key>
install_manual_cert() {
  local d="$1" crt="$2" key="$3"
  [[ -s "$crt" && -s "$key" ]] || die "Файлы сертификата/ключа не найдены."
  openssl x509 -in "$crt" -noout >/dev/null 2>&1 || die "$crt — не похоже на сертификат."
  install -d -m 700 "$(store_dir "$d")"
  install -m 644 "$crt" "$(cert_path "$d")"
  install -m 600 "$key" "$(cert_key_path "$d")"
  log "Сертификат для $d установлен из файлов (автопродления нет)."
}

# Removes a domain's OWN certificate (never a wildcard shared with others).
remove_cert() {
  local d="$1"
  if acme_installed; then
    acme --remove -d "$d" --ecc >/dev/null 2>&1 || true
    rm -rf "${ACME_HOME:?}/data/${d}_ecc" "${ACME_HOME:?}/certs/${d}_ecc"
  fi
  rm -rf "${NGINX_SSL:?}/$d"
}

renew_all() {
  ensure_acme
  info "Продлеваю сертификаты, срок которых подходит..."
  acme --cron || warn "acme.sh --cron завершился с ошибкой."
}

cert_list() {
  title "Сертификаты"
  local n d users
  for n in $(store_names); do
    users=""
    for d in $(list_domains); do [[ "$(domain_cert_name "$d")" == "$n" ]] && users+="$d "; done
    if is_wildcard_name "$n"; then
      printf ' %s*.%-32s%s %s\n' "$C_BOLD" "${n#star.}" "$C_RESET" "$(store_summary "$n")"
    else
      printf ' %s%-34s%s %s\n' "$C_BOLD" "$n" "$C_RESET" "$(store_summary "$n")"
    fi
    printf '   %-34s %s\n' "" "${users:+домены: $users}"
  done
  [[ -n "$(store_names)" ]] || info "Сертификатов нет."
  printf '%sПапка: %s — каждую подпапку можно переносить на другую ноду как есть.%s\n' "$C_DIM" "$NGINX_SSL" "$C_RESET"
}
