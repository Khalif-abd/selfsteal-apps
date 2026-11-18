# shellcheck shell=bash
# Main-screen dashboard: nginx version, IP access, domains with certificate state, apps.
# Built from local data only (config, cert files, docker) — no network, so the menu stays instant.

DASH_MAX_DOMAINS="${SSA_DASH_DOMAINS:-5}"   # domains shown on the main screen; the rest -> "… ещё N"
CERT_WARN_DAYS=14

ui_emoji() { [[ "${UI_EMOJI:-1}" == "1" && "${SSA_NO_EMOJI:-0}" != "1" ]]; }

# ic EMOJI — icon + space, or nothing when emoji are off.
# Only wide emoji without VS16 (️) here: those keep the same width in every terminal.
ic() { ui_emoji && printf '%s ' "$1"; return 0; }

# dot ok|warn|bad — status mark: colored circle emoji, or a colored ● without emoji.
dot() {
  if ui_emoji; then
    case "$1" in ok) printf '🟢';; warn) printf '🟡';; *) printf '🔴';; esac
  else
    case "$1" in ok) printf '%s●%s' "$C_GREEN" "$C_RESET";; warn) printf '%s●%s' "$C_YELLOW" "$C_RESET";;
                 *) printf '%s●%s' "$C_RED" "$C_RESET";; esac
  fi
}

# Version of the running nginx ("1.30.7"), empty if the container is down.
nginx_version() {
  docker exec "$CONTAINER" nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p' | head -1 || true
}

# Is any container of an app's compose project running? (projects are named ssa-<app>)
app_running() {
  [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=ssa-$1" 2>/dev/null | head -1)" ]]
}

# Short label of what a domain serves (domain record must be loaded).
_dash_target() {
  case "$APP" in
    stub)  printf 'заглушка %s' "$PAGE";;
    proxy) printf 'прокси → %s' "${UPSTREAM#http://}";;
    *)     printf '%s' "$(app_title "$APP")";;
  esac
}

# _dash_cert DOMAIN -> "state<TAB>days" ; state: ok | warn | bad | none
_dash_cert() {
  local d="$1" n days
  n="$(domain_cert_name "$d")"
  store_has "$n" || { printf 'none\t-\n'; return; }
  days="$(_store_days_left "$n" 2>/dev/null || true)"
  if ! [[ "$days" =~ ^-?[0-9]+$ ]]; then printf 'warn\t?\n'
  elif (( days < 0 )); then printf 'bad\t%s\n' "$days"
  elif (( days < CERT_WARN_DAYS )); then printf 'warn\t%s\n' "$days"
  else printf 'ok\t%s\n' "$days"
  fi
}

_dash_line() {
  local s
  s="$(printf '%*s' 60 '')"
  printf ' %s%s%s\n' "$C_DIM" "${s// /─}" "$C_RESET"
}

dash_header() {
  local st
  if ! is_installed; then st="$(dot warn) не установлено"
  elif container_running; then st="$(dot ok) nginx работает"
  else st="$(dot bad) ${C_RED}nginx остановлен${C_RESET}"
  fi
  printf ' %s%sselfsteal-apps %s%s   %s\n' "$C_BOLD$C_CYAN" "$(ic 🔰)" "$SSA_VERSION" "$C_RESET" "$st"
  _dash_line
}

_dash_nginx() {
  local v mode
  v="$(container_running && nginx_version || true)"
  if [[ "$LISTEN_MODE" == socket ]]; then mode="сокеты"; else mode="tcp"; fi
  printf ' %snginx %s%s%s  %s(%s)%s · порты Xray: %s · %s\n' "$(ic 🧩)" "$C_BOLD" "${v:-?}" "$C_RESET" \
    "$C_DIM" "$NGINX_IMAGE" "$C_RESET" "$(site_ports | paste -sd, - | sed 's/,/, /g')" "$mode"
}

_dash_ip() {
  local s ip="${PUBLIC_IP:-<IP>}"
  if s="$(ip_access_site)"; then
    printf ' %sДоступ по IP: %sвключён%s — %s открывает сайт %s\n' "$(ic 🌐)" "$C_GREEN" "$C_RESET" \
      "$(public_url "$ip" "$(site_port "$s")")" "$(site_label "$s")"
  elif [[ "${IP_ACCESS:-0}" == "1" ]]; then
    printf ' %sДоступ по IP: %sвключён, но нет домена с сертификатом%s — соединения обрываются\n' \
      "$(ic 🌐)" "$C_YELLOW" "$C_RESET"
  else
    printf ' %sДоступ по IP: выключен — на https://%s соединение обрывается, сайт не видно\n' "$(ic 🌐)" "$ip"
  fi
}

_dash_domains() {
  local d sid rows=() problems=0 total=0 ndom w=12 state days line target
  ndom="$(list_domains | grep -c . || true)"
  for sid in $(list_sites); do
    load_site "$sid" || continue
    d="$DOMAIN"
    total=$((total+1))
    IFS=$'\t' read -r state days < <(_dash_cert "$d")
    target="$(_dash_target)"
    [[ "$(domain_cert_name "$d")" == star.* ]] && target+=" · wildcard"
    # sort key: problems first, then by name
    if [[ "$state" == ok ]]; then line="1"; else line="0"; problems=$((problems+1)); fi
    rows+=("${line}"$'\t'"$(site_label "$sid")"$'\t'"${state}"$'\t'"${days}"$'\t'"${target}")
  done
  printf '\n %s%sДомены (%d)%s' "$C_BOLD" "$(ic 🌍)" "$ndom" "$C_RESET"
  if (( total == 0 )); then
    printf '\n   %sпока нет — добавьте в разделе «Домены»%s\n' "$C_DIM" "$C_RESET"
    return
  fi
  if (( problems )); then printf '   %s%d требуют внимания%s\n' "$C_YELLOW" "$problems" "$C_RESET"
  else printf '   %sсертификаты в порядке%s\n' "$C_DIM" "$C_RESET"
  fi

  # problems first, then by name; only the first DASH_MAX_DOMAINS — column width from those
  local top=() r key mark cert shown
  mapfile -t top < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1 -k2,2 | head -n "$DASH_MAX_DOMAINS")
  shown=${#top[@]}
  for r in "${top[@]}"; do d="$(cut -f2 <<<"$r")"; (( ${#d} > w )) && w=${#d}; done
  (( w > 36 )) && w=36
  for r in "${top[@]}"; do
    IFS=$'\t' read -r key d state days target <<<"$r"
    case "$state" in
      none) mark="$(dot bad)"; cert="${C_RED}нет серт.${C_RESET}" ;;
      bad)  mark="$(dot bad)"; cert="${C_RED}истёк    ${C_RESET}" ;;
      warn) mark="$(dot warn)"; cert="${C_YELLOW}$(printf '%3s дн.  ' "$days")${C_RESET}" ;;
      *)    mark="$(dot ok)"; cert="$(printf '%3s дн.  ' "$days")" ;;
    esac
    # fixed-width columns are ASCII; the Cyrillic/free-form target goes last so it can't break alignment
    printf '   %-*s  %s %s  %s%s%s\n' "$w" "$d" "$mark" "$cert" "$C_DIM" "$target" "$C_RESET"
  done
  (( total > shown )) && printf '   %s… ещё %d — все в разделе «Домены»%s\n' "$C_DIM" "$((total - shown))" "$C_RESET"
  return 0
}

_dash_apps() {
  local a any=0 ver
  for a in $(available_apps); do
    app_installed "$a" || continue
    if (( ! any )); then printf '\n %s%sПриложения%s\n' "$C_BOLD" "$(ic 📦)" "$C_RESET"; any=1; fi
    ver=""; app_has "$a" version && ver="$("${a}_version" 2>/dev/null || true)"
    if app_running "$a"; then
      printf '   %-12s  %s %s\n' "$(app_title "$a")" "$(dot ok)" "${ver:-работает}"
    else
      printf '   %-12s  %s %sостановлено%s%s\n' "$(app_title "$a")" "$(dot bad)" "$C_RED" "$C_RESET" "${ver:+ · $ver}"
    fi
  done
  return 0
}

dashboard() {
  dash_header
  is_installed || return 0
  _dash_nginx
  _dash_ip
  local prob; prob="$(doctor_brief)"
  [[ -n "$prob" ]] && printf ' %s%s%s%s — «Сервис» → «Диагностика»\n' "$(ic 🚨)" "$C_RED" "$prob" "$C_RESET"
  _dash_domains
  _dash_apps
  _dash_line
}
