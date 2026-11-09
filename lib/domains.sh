# shellcheck shell=bash
# Domain management. Each domain = own server block + own certificate + one app.
# Domains are independent: subdomains of one zone and unrelated zones are equal.

STUB_PAGES=(403 404 502 503 welcome)

page_label() {
  case "$1" in
    403) echo "403 Forbidden (nginx)";;
    404) echo "404 Not Found (nginx)";;
    502) echo "502 Bad Gateway (nginx)";;
    503) echo "503 Service Unavailable (nginx)";;
    welcome) echo "Welcome to nginx! (дефолтная страница)";;
    *) echo "$1";;
  esac
}

app_label() {
  case "$APP" in
    stub)  printf 'заглушка: %s' "$(page_label "$PAGE")";;
    proxy) printf 'прокси -> %s' "$UPSTREAM";;
    *)     printf '%s' "$APP";;
  esac
}

valid_upstream() { [[ "$1" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; }

_pick_page() {
  local labels=() p choice
  for p in "${STUB_PAGES[@]}"; do labels+=("$(page_label "$p")"); done
  choose choice "Что отдавать на этом домене?" 1 "${labels[@]}"
  for p in "${STUB_PAGES[@]}"; do [[ "$(page_label "$p")" == "$choice" ]] && { PAGE="$p"; return; }; done
}

# Get a certificate for a domain that has none.
# domain_obtain_cert DOMAIN MODE [cf-token] [cf-zone-id]
#   MODE: auto | http | wildcard | none
#   auto: interactive -> ask; otherwise wildcard if Cloudflare creds for the zone are saved, else http-01
domain_obtain_cert() {
  local d="$1" mode="${2:-auto}" token="${3:-}" zid="${4:-}" zone w
  zone="$(registrable_zone "$d")"
  if has_cert "$d"; then
    w="$(covering_wildcard "$d" || true)"
    if [[ -n "$w" ]]; then
      _set_cert_source "$d" wildcard
      log "$d: используется wildcard *.${w#star.}"
    fi
    return 0
  fi
  if [[ "$mode" == auto ]]; then
    if is_interactive; then
      local c def=1
      [[ -f "$(_cf_file "$zone")" ]] && def=2
      choose c "Сертификат для $d" "$def" \
        "Отдельный на $d (http-01, нужен открытый TCP/80)" \
        "Wildcard *.$zone через Cloudflare (покроет все поддомены)" \
        "Импортировать готовый (архив/файлы с другой ноды)" \
        "Пока без сертификата"
      case "$c" in
        Отдельный*) mode=http;;
        Wildcard*)  mode=wildcard;;
        Импорт*)    mode=import;;
        *)          mode=none;;
      esac
    elif [[ -f "$(_cf_file "$zone")" ]]; then mode=wildcard
    else mode=http
    fi
  fi
  case "$mode" in
    none) warn "Сертификата нет — TLS для $d не активен." ;;
    http) issue_cert "$d" || warn "TLS для $d пока не активен. Повторите: selfsteal-apps cert issue $d" ;;
    wildcard)
      local a=("$zone"); [[ -n "$token" ]] && a+=(--cf-token "$token"); [[ -n "$zid" ]] && a+=(--cf-zone-id "$zid")
      ( wildcard_issue "${a[@]}" ) || warn "Wildcard не выпущен. Повторите: selfsteal-apps cert wildcard $zone"
      has_cert "$d" && _set_cert_source "$d" wildcard ;;
    import) ( cert_import ) || warn "Импорт не удался." ;;
  esac
  return 0
}

# domain_add DOMAIN [--page P | --proxy URL] [--wildcard [--cf-token T --cf-zone-id ID] | --http | --cert F --key K | --no-cert]
domain_add() {
  local d="" page="" upstream="" crt="" key="" mode="auto" token="" zid=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --page) page="${2:-}"; shift 2;;
      --proxy) upstream="${2:-}"; shift 2;;
      --cert) crt="${2:-}"; shift 2;;
      --key) key="${2:-}"; shift 2;;
      --no-cert) mode=none; shift;;
      --http) mode=http; shift;;
      --wildcard) mode=wildcard; shift;;
      --cf-token) token="${2:-}"; shift 2;;
      --cf-zone-id) zid="${2:-}"; shift 2;;
      -*) die "Неизвестная опция: $1";;
      *) d="$1"; shift;;
    esac
  done

  [[ -n "$d" ]] || ask d "Домен (например meet.example.com)"
  d="$(lower "$d")"
  valid_domain "$d" || die "Некорректный домен: '$d'"
  domain_exists "$d" && die "Домен $d уже добавлен. Используйте 'domain set'."

  DOMAIN="$d"; APP="stub"; PAGE="403"; UPSTREAM=""; CERT_SOURCE="acme"; ADDED_AT="$(date +%F)"

  if [[ -n "$upstream" ]]; then
    valid_upstream "$upstream" || die "Некорректный upstream: $upstream (пример: http://127.0.0.1:8000)"
    APP="proxy"; UPSTREAM="$upstream"
  elif [[ -n "$page" ]]; then
    [[ " ${STUB_PAGES[*]} " == *" $page "* ]] || die "Страница: ${STUB_PAGES[*]}"
    PAGE="$page"
  elif is_interactive; then
    local kind
    choose kind "Что будет на домене?" 1 \
      "Заглушка nginx (403/404/502/503/welcome)" \
      "Прокси на локальный сервис (http://127.0.0.1:PORT)"
    if [[ "$kind" == Прокси* ]]; then
      APP="proxy"
      ask UPSTREAM "Upstream" "http://127.0.0.1:8000"
      valid_upstream "$UPSTREAM" || die "Некорректный upstream: $UPSTREAM"
    else
      _pick_page
    fi
  fi

  [[ -n "$crt" || -n "$key" ]] && CERT_SOURCE="manual"
  save_domain
  apply_config || { rm -f "$(domain_file "$d")"; die "Не удалось применить конфиг — домен не добавлен."; }

  if [[ "$CERT_SOURCE" == "manual" ]]; then
    install_manual_cert "$d" "$crt" "$key"
  else
    domain_obtain_cert "$d" "$mode" "$token" "$zid"
  fi
  apply_config

  log "Домен $d добавлен: $(load_domain "$d"; app_label)"
  xray_domain_hint "$d"
}

domain_remove() {
  local d="${1:-}"
  [[ -n "$d" ]] || { pick_domain d || return 0; }
  domain_exists "$d" || die "Домен $d не найден."
  confirm "Удалить $d (конфиг и сертификат)?" n || return 0
  rm -f "$(domain_file "$d")"
  remove_cert "$d"
  apply_config
  log "Домен $d удалён. Не забудьте убрать его из serverNames в Remnawave."
}

# domain_set DOMAIN [--page P | --proxy URL]
domain_set() {
  local d="" page="" upstream=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --page) page="${2:-}"; shift 2;;
      --proxy) upstream="${2:-}"; shift 2;;
      -*) die "Неизвестная опция: $1";;
      *) d="$1"; shift;;
    esac
  done
  [[ -n "$d" ]] || { pick_domain d || return 0; }
  load_domain "$d" || die "Домен $d не найден."

  if [[ -n "$upstream" ]]; then
    valid_upstream "$upstream" || die "Некорректный upstream: $upstream"
    APP="proxy"; UPSTREAM="$upstream"
  elif [[ -n "$page" ]]; then
    [[ " ${STUB_PAGES[*]} " == *" $page "* ]] || die "Страница: ${STUB_PAGES[*]}"
    APP="stub"; PAGE="$page"; UPSTREAM=""
  elif is_interactive; then
    local kind
    choose kind "Что отдавать на $d? (сейчас: $(app_label))" 1 \
      "Заглушка nginx" "Прокси на локальный сервис"
    if [[ "$kind" == Прокси* ]]; then
      APP="proxy"; ask UPSTREAM "Upstream" "${UPSTREAM:-http://127.0.0.1:8000}"
      valid_upstream "$UPSTREAM" || die "Некорректный upstream: $UPSTREAM"
    else
      APP="stub"; UPSTREAM=""; _pick_page
    fi
  else
    die "Укажите --page или --proxy."
  fi
  save_domain
  apply_config
  log "$d: $(app_label)"
}

domain_list() {
  local d n=0
  title "Домены"
  for d in $(list_domains); do
    load_domain "$d" || continue
    n=$((n+1))
    printf ' %s%-34s%s %s\n' "$C_BOLD" "$d" "$C_RESET" "$(app_label)"
    printf '   %-34s TLS: %s\n' "" "$(cert_summary "$d")"
  done
  (( n )) || info "Доменов пока нет. Добавьте: selfsteal-apps domain add <домен>"
}

# pick_domain VAR — interactive selection; returns 1 if nothing to pick.
pick_domain() {
  local __v="$1" ds
  mapfile -t ds < <(list_domains)
  (( ${#ds[@]} )) || { info "Доменов нет."; return 1; }
  if (( ${#ds[@]} == 1 )) || ! is_interactive; then
    printf -v "$__v" '%s' "${ds[0]}"
    is_interactive || (( ${#ds[@]} == 1 )) || die "Укажите домен явно."
    return 0
  fi
  choose "$__v" "Домен" 1 "${ds[@]}"
}
