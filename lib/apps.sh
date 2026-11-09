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
  if ! has_cert "$d"; then
    issue_cert "$d" || warn "TLS для $d пока не активен. Повторите: selfsteal-apps cert issue $d"
    apply_config
  fi
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
