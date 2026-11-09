# shellcheck shell=bash
# Application plugins: apps/<name>/app.sh
#
# A plugin sets <name>_TITLE / <name>_DESC and defines (all optional except install):
#   <name>_install [args]     install or reconfigure (idempotent)
#   <name>_uninstall          remove the app, keep the domain (back to a stub)
#   <name>_status             print status
#   <name>_logs [service]     follow logs
#   <name>_update             update to the newest stable release
#   <name>_cmd <sub> [args]   extra subcommands (e.g. users)
#   <name>_menu_extra         extra interactive menu entries
#   <name>_nginx_locations    location blocks for the domain's TLS server (uses UPSTREAM)
#   <name>_installed          return 0 if installed

APPS_STATE_DIR="$CONF_DIR/apps"
APPS_DATA_DIR="$DATA_DIR/apps"

load_app_plugins() {
  local f
  shopt -s nullglob
  for f in "$SSA_LIB"/apps/*/app.sh; do
    # shellcheck disable=SC1090
    source "$f"
  done
  shopt -u nullglob
}

available_apps() {
  local f
  shopt -s nullglob
  for f in "$SSA_LIB"/apps/*/app.sh; do basename "$(dirname "$f")"; done
  shopt -u nullglob
}

app_known() { declare -F "${1}_install" >/dev/null; }
app_has()   { declare -F "${1}_$2" >/dev/null; }

app_title() { local v="${1}_TITLE"; printf '%s' "${!v:-$1}"; }
app_desc()  { local v="${1}_DESC";  printf '%s' "${!v:-}"; }

app_installed() { app_has "$1" installed && "${1}_installed"; }

# Free RAM check before installing an app (<name>_MEM_MB = what it needs).
app_check_memory() {
  local a="$1" v need avail total
  v="${a}_MEM_MB"; need="${!v:-0}"
  (( need > 0 )) || return 0
  avail="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  total="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  (( avail > 0 )) || return 0
  if (( avail < need + 256 )); then
    warn "$(app_title "$a") нужно ~${need} МБ RAM, а свободно ${avail} из ${total} МБ (с учётом уже запущенного)."
    local a2 others=""
    for a2 in $(available_apps); do [[ "$a2" != "$a" ]] && app_installed "$a2" && others+="$(app_title "$a2") "; done
    [[ -n "$others" ]] && info "Уже установлены: $others"
    confirm "Всё равно ставить?" n || die "Отменено."
  else
    info "RAM: свободно ${avail} МБ, $(app_title "$a") нужно ~${need} МБ — ок."
  fi
}

# One domain = one app.
_app_domain_conflict() {
  local a="$1" d="$2" cur
  domain_exists "$d" || return 0
  cur="$(_domain_field "$d" APP)"
  case "$cur" in
    stub|proxy|"$a"|"") return 0 ;;
    *) die "Домен $d уже занят приложением $(app_title "$cur"). Выберите другой домен." ;;
  esac
}

# Memory used by an app's compose project, in MiB.
app_mem_usage() {
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null | awk -v p="ssa-$1-" '
    index($1, p) == 1 {
      v = $2; u = v; gsub(/[0-9.]/, "", u); gsub(/[^0-9.]/, "", v)
      if (u == "GiB") v *= 1024; else if (u == "KiB") v /= 1024; else if (u == "B") v /= 1048576
      s += v
    }
    END { printf "%d", s }'
}

apps_status_brief() {
  local a any=0 d
  for a in $(available_apps); do
    app_installed "$a" || continue
    (( any )) || title "Приложения"
    any=1
    d=""; app_has "$a" brief && d="$("${a}_brief")"
    printf ' %s%-14s%s %-32s RAM: ~%s МБ\n' "$C_BOLD" "$(app_title "$a")" "$C_RESET" "${d:+https://$d}" "$(app_mem_usage "$a")"
  done
  return 0
}

# Bind a domain to an app: creates the domain (with certificate) if needed.
domain_ensure() {
  local d="$1" app="$2" upstream="$3"
  if domain_exists "$d"; then
    load_domain "$d"
    APP="$app"; UPSTREAM="$upstream"
    save_domain
    apply_config
  else
    DOMAIN="$d"; APP="$app"; PAGE="403"; UPSTREAM="$upstream"; CERT_SOURCE="acme"; ADDED_AT="$(date +%F)"
    save_domain
    apply_config || { rm -f "$(domain_file "$d")"; die "Не удалось применить конфиг для $d."; }
    xray_domain_hint "$d"
  fi
  domain_obtain_cert "$d" auto
  apply_config
}

# Return a domain to a neutral stub when its app goes away.
domain_release() {
  local d="$1" app="$2"
  domain_exists "$d" || return 0
  load_domain "$d"
  [[ "$APP" == "$app" ]] || return 0
  APP="stub"; PAGE="403"; UPSTREAM=""
  save_domain
  apply_config
  info "$d теперь отдаёт заглушку 403."
}

app_list() {
  title "Приложения"
  local a st
  for a in $(available_apps); do
    if app_installed "$a"; then st="${C_GREEN}установлено${C_RESET}"; else st="${C_DIM}не установлено${C_RESET}"; fi
    printf ' %s%-10s%s %-28s %s\n' "$C_BOLD" "$a" "$C_RESET" "$st" "$(app_desc "$a")"
  done
}

# selfsteal-apps app [list] | app <name> <install|uninstall|status|logs|update|...> [args]
app_cmd() {
  local name="${1:-}"; shift || true
  case "$name" in
    ""|list|ls) app_list; return ;;
  esac
  app_known "$name" || die "Неизвестное приложение: $name. Доступны: $(available_apps | tr '\n' ' ')"
  local sub="${1:-status}"; shift || true
  case "$sub" in
    install|uninstall|status|logs|update)
      [[ "$sub" == install ]] || app_has "$name" "$sub" || die "$name: команда $sub не поддерживается."
      [[ "$sub" == install ]] && { is_installed || die "Сначала установите ядро: selfsteal-apps install"; }
      "${name}_${sub}" "$@"
      ;;
    *)
      app_has "$name" cmd || die "$name: неизвестная команда $sub"
      "${name}_cmd" "$sub" "$@"
      ;;
  esac
}
