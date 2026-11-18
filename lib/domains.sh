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
    *)     printf '%s' "$(app_title "$APP")";;
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

# Port of a new site: --port, else ask (interactive), else PUBLIC_PORT.
_ask_public_port() {
  local __v="$1" given="${2:-}" p
  if [[ -n "$given" ]]; then p="$given"
  elif is_interactive; then ask p "Публичный порт (порт Xray inbound, куда приходит клиент)" "$PUBLIC_PORT"
  else p="$PUBLIC_PORT"
  fi
  valid_public_port "$p" || die "Некорректный публичный порт: '$p' (1-65535, не 80)."
  printf -v "$__v" '%s' "$p"
}

# Is the loaded site taken by an app plugin (jitsi, nextcloud, ...)?
_site_is_app() { [[ "$APP" != stub && "$APP" != proxy ]]; }

# domain_add DOMAIN [--port P] [--page P | --proxy URL] [--wildcard [--cf-token T --cf-zone-id ID] | --http | --cert F --key K | --no-cert]
domain_add() {
  local d="" page="" upstream="" crt="" key="" mode="auto" token="" zid="" port_arg="" port sid
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) port_arg="${2:-}"; shift 2;;
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
  _ask_public_port port "$port_arg"
  sid="$(site_id "$d" "$port")"
  site_exists "$sid" && die "$(site_label "$sid") уже добавлен. Изменить: selfsteal-apps domain set $d --port $port"

  local had_domain=0; domain_exists "$d" && had_domain=1
  local cert_src="acme"; (( had_domain )) && cert_src="$(_domain_field "$d" CERT_SOURCE)"
  DOMAIN="$d"; PORT="$port"; APP="stub"; PAGE="403"; UPSTREAM=""; CERT_SOURCE="${cert_src:-acme}"; ADDED_AT="$(date +%F)"

  if [[ -n "$upstream" ]]; then
    valid_upstream "$upstream" || die "Некорректный upstream: $upstream (пример: http://127.0.0.1:8000)"
    APP="proxy"; UPSTREAM="$upstream"
  elif [[ -n "$page" ]]; then
    [[ " ${STUB_PAGES[*]} " == *" $page "* ]] || die "Страница: ${STUB_PAGES[*]}"
    PAGE="$page"
  elif is_interactive; then
    local kind
    choose kind "Что будет на $(site_label "$sid")?" 1 \
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
  ensure_port_listener "$port"
  save_site
  apply_config || { rm -f "$(site_file "$sid")"; die "Не удалось применить конфиг — $(site_label "$sid") не добавлен."; }

  if [[ "$CERT_SOURCE" == "manual" && -n "$crt$key" ]]; then
    install_manual_cert "$d" "$crt" "$key"
  elif (( had_domain )) && has_cert "$d"; then
    info "Сертификат $d уже есть — он общий для всех портов домена."
  else
    domain_obtain_cert "$d" "$mode" "$token" "$zid"
  fi
  apply_config

  log "Добавлен $(site_label "$sid"): $(load_site "$sid"; app_label)"
  xray_domain_hint "$d" "$port"
}

# pick_site VAR [DOMAIN] [PORT] — resolve a site; asks when a domain has several ports.
pick_site() {
  local __v="$1" d="${2:-}" p="${3:-}" ss labels=() s c
  if [[ -n "$d" && -n "$p" ]]; then
    site_exists "$(site_id "$d" "$p")" || die "$d на порту $p не найден."
    printf -v "$__v" '%s' "$(site_id "$d" "$p")"; return 0
  fi
  if [[ -n "$d" ]]; then
    mapfile -t ss < <(sites_of "$d")
    (( ${#ss[@]} )) || die "Домен $d не найден."
  else
    mapfile -t ss < <(list_sites)
    (( ${#ss[@]} )) || { info "Доменов нет."; return 1; }
  fi
  if (( ${#ss[@]} == 1 )); then printf -v "$__v" '%s' "${ss[0]}"; return 0; fi
  is_interactive || die "У $d несколько портов ($(printf '%s\n' "${ss[@]}" | cut -d@ -f2 | paste -sd, -)) — укажите --port."
  for s in "${ss[@]}"; do labels+=("$(site_label "$s")  —  $(load_site "$s"; app_label)"); done
  choose c "Какой" 1 "${labels[@]}"
  for s in "${!labels[@]}"; do [[ "${labels[$s]}" == "$c" ]] && { printf -v "$__v" '%s' "${ss[$s]}"; return 0; }; done
  return 1
}

# domain remove DOMAIN [--port P]
domain_remove() {
  local d="" p="" sid
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) p="${2:-}"; shift 2;;
      -*) die "Неизвестная опция: $1";;
      *) d="$(lower "$1")"; shift;;
    esac
  done
  pick_site sid "$d" "$p" || return 0
  d="$(site_domain "$sid")"
  load_site "$sid"
  if _site_is_app; then
    die "На $(site_label "$sid") работает $(app_title "$APP"). Сначала удалите приложение: selfsteal-apps app $APP uninstall"
  fi
  local last=0; [[ "$(sites_of "$d" | wc -l)" -eq 1 ]] && last=1
  if (( last )); then
    confirm "Удалить $(site_label "$sid") (конфиг и сертификат домена)?" n || return 0
  else
    confirm "Удалить $(site_label "$sid")? Другие порты домена и сертификат останутся." n || return 0
  fi
  rm -f "$(site_file "$sid")"
  apply_config
  # only after nginx no longer references it: a reload must never see a config pointing to deleted files
  (( last )) && remove_cert "$d"
  log "Удалён $(site_label "$sid"). Не забудьте убрать $d из serverNames inbound на порту $(site_port "$sid") в Remnawave."
}

# domain set DOMAIN [--port P] --page P | --proxy URL
domain_set() {
  local d="" p="" page="" upstream="" sid
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) p="${2:-}"; shift 2;;
      --page) page="${2:-}"; shift 2;;
      --proxy) upstream="${2:-}"; shift 2;;
      -*) die "Неизвестная опция: $1";;
      *) d="$(lower "$1")"; shift;;
    esac
  done
  pick_site sid "$d" "$p" || return 0
  load_site "$sid" || die "$sid не найден."
  if _site_is_app; then
    warn "На $(site_label "$sid") сейчас работает $(app_title "$APP") — после изменения он перестанет открываться по этому адресу."
    confirm "Всё равно изменить?" n || return 0
  fi

  if [[ -n "$upstream" ]]; then
    valid_upstream "$upstream" || die "Некорректный upstream: $upstream"
    APP="proxy"; UPSTREAM="$upstream"
  elif [[ -n "$page" ]]; then
    [[ " ${STUB_PAGES[*]} " == *" $page "* ]] || die "Страница: ${STUB_PAGES[*]}"
    APP="stub"; PAGE="$page"; UPSTREAM=""
  elif is_interactive; then
    local kind
    choose kind "Что отдавать на $(site_label "$sid")? (сейчас: $(app_label))" 1 \
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
  save_site
  apply_config
  log "$(site_label "$sid"): $(app_label)"
}

domain_list() {
  local d s n=0
  title "$(ic 🌍)Домены"
  for d in $(list_domains); do
    n=$((n+1))
    printf ' %s%s%s\n' "$C_BOLD" "$d" "$C_RESET"
    printf '   TLS: %s\n' "$(cert_summary "$d")"
    for s in $(sites_of "$d"); do
      load_site "$s" || continue
      printf '   порт %-6s → %s\n' "$PORT" "$(app_label)"
    done
  done
  (( n )) || info "Доменов пока нет. Добавьте: selfsteal-apps domain add <домен>"
}

# pick_domain VAR — interactive selection of a domain (certificates); returns 1 if nothing to pick.
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
