# shellcheck shell=bash
# Interactive menu. Every action maps 1:1 to a CLI command.

# Run an action without letting die()/set -e kill the menu loop.
_menu_run() {
  ( "$@" ) || warn "Действие завершилось с ошибкой."
  pause
}

_menu_header() {
  load_config   # actions run in subshells; pick up what they saved
  clear 2>/dev/null || true
  dash_header
}

# _menu_item N ICON TEXT
_menu_item() { printf '  %s%s)%s %s%s\n' "$C_BOLD" "$1" "$C_RESET" "$(ic "$2")" "$3"; }

_menu_prompt() { echo; read -r -p "$(printf '%sВыбор:%s ' "$C_CYAN" "$C_RESET")" "$1"; }

_menu_domains() {
  while :; do
    _menu_header
    domain_list
    echo
    ip_status
    echo
    local ipt="Включить показ сайта по IP"
    [[ "${IP_ACCESS:-0}" == "1" ]] && ipt="Выключить показ сайта по IP"
    _menu_item 1 ➕ "Добавить домен"
    _menu_item 2 📝 "Изменить содержимое домена"
    _menu_item 3 🔀 "Сменить порт домена"
    _menu_item 4 ❌ "Удалить домен"
    _menu_item 5 🌐 "$ipt"
    [[ "${IP_ACCESS:-0}" == "1" ]] && _menu_item 6 🔁 "Сменить сайт, который показывается по IP"
    _menu_item 0 🔙 "Назад"
    local c; _menu_prompt c || return 0
    case "$c" in
      1) _menu_run domain_add ;;
      2) _menu_run domain_set ;;
      3) _menu_run domain_move ;;
      4) _menu_run domain_remove ;;
      5) if [[ "${IP_ACCESS:-0}" == "1" ]]; then _menu_run ip_cmd off; else _menu_run ip_cmd on; fi ;;
      6) [[ "${IP_ACCESS:-0}" == "1" ]] && _menu_run ip_cmd on ;;
      0|"") return 0 ;;
    esac
  done
}

_menu_certs() {
  while :; do
    _menu_header
    cert_list
    echo
    _menu_item 1 🌟 "Wildcard через Cloudflare (*.зона + зона)"
    _menu_item 2 📄 "Отдельный сертификат для домена (http-01)"
    _menu_item 3 🔁 "Перевыпустить принудительно"
    _menu_item 4 📤 "Экспорт — для переноса на другую ноду"
    _menu_item 5 📥 "Импорт — архив/папка/файлы с другой ноды"
    _menu_item 6 ⏳ "Продлить все, у которых подходит срок"
    _menu_item 7 ❌ "Удалить wildcard"
    _menu_item 0 🔙 "Назад"
    local c; _menu_prompt c || return 0
    case "$c" in
      1) _menu_run cert_cmd wildcard ;;
      2) _menu_run cert_cmd issue ;;
      3) _menu_run cert_cmd reissue ;;
      4) _menu_run cert_cmd export ;;
      5) _menu_run cert_cmd import ;;
      6) _menu_run cert_cmd renew ;;
      7) _menu_run cert_cmd wildcard remove ;;
      0|"") return 0 ;;
    esac
  done
}

_menu_service() {
  while :; do
    _menu_header
    local v; v="$(container_running && nginx_version || true)"
    printf ' %snginx %s%s%s (%s)\n\n' "$(ic 🧩)" "$C_BOLD" "${v:-не запущен}" "$C_RESET" "$NGINX_IMAGE"
    local et="Выключить значки в меню"; ui_emoji || et="Включить значки в меню"
    _menu_item 1 🔄 "Перезапустить nginx (пересоздать контейнер)"
    _menu_item 2 🆕 "Обновить nginx (скачать свежий образ)"
    _menu_item 3 📜 "Логи nginx (Ctrl+C — выход)"
    _menu_item 4 🔌 "Проверить доступ Xray к сокету"
    _menu_item 5 ⛔ "Остановить nginx"
    _menu_item 6 🩺 "Диагностика (связь с Xray, NAT, cron, порты)"
    _menu_item 7 🎨 "$et"
    _menu_item 0 🔙 "Назад"
    local c; _menu_prompt c || return 0
    case "$c" in
      1) _menu_run restart_cmd ;;
      2) _menu_run nginx_update_cmd ;;
      3) ( logs_cmd 100 ) || true ;;
      4) _menu_run check_xray_socket_access ;;
      5) _menu_run down_cmd ;;
      6) _menu_run doctor_cmd ;;
      7) if ui_emoji; then UI_EMOJI=0; else UI_EMOJI=1; fi; save_config ;;
      0|"") return 0 ;;
    esac
  done
}

# Current public port of an app (from its address).
_menu_app_port() {
  local u=""; app_has "$1" brief && u="$("${1}_brief" 2>/dev/null || true)"
  [[ "$u" =~ :([0-9]+)$ ]] && printf '%s' "${BASH_REMATCH[1]}" || printf '443'
}

_menu_app() {
  local a="$1"
  while :; do
    _menu_header
    ( "${a}_status" ) 2>/dev/null || true
    echo
    if app_installed "$a"; then
      _menu_item 1 🔧 "Переустановить / изменить настройки"
      _menu_item 2 🆕 "Обновить до последней стабильной версии"
      _menu_item 3 📜 "Логи (Ctrl+C — выход)"
      _menu_item 4 ❌ "Удалить"
      app_has "$a" set_port && _menu_item 5 🔀 "Сменить порт (сейчас $(_menu_app_port "$a"))"
      app_has "$a" menu_extra && "${a}_menu_extra"
    else
      _menu_item 1 📥 "Установить"
    fi
    _menu_item 0 🔙 "Назад"
    local c; _menu_prompt c || return 0
    case "$c" in
      0|"") return 0 ;;
      1) _menu_run "${a}_install" ;;
      2) app_installed "$a" && _menu_run "${a}_update" ;;
      3) app_installed "$a" && { ( "${a}_logs" ) || true; } ;;
      4) app_installed "$a" && _menu_run "${a}_uninstall" ;;
      5) app_installed "$a" && app_has "$a" set_port && _menu_run "${a}_set_port" ;;
      *) if app_installed "$a" && app_has "$a" menu_action; then _menu_run "${a}_menu_action" "$c"; fi ;;
    esac
  done
}

_menu_apps() {
  while :; do
    _menu_header
    app_list
    echo
    local apps i=1 a
    mapfile -t apps < <(available_apps)
    for a in "${apps[@]}"; do _menu_item "$i" "$(app_icon "$a")" "$(app_title "$a")"; i=$((i+1)); done
    _menu_item 0 🔙 "Назад"
    local c; _menu_prompt c || return 0
    [[ "$c" == 0 || -z "$c" ]] && return 0
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#apps[@]} )); then
      _menu_app "${apps[$((c-1))]}"
    fi
  done
}

main_menu() {
  is_interactive || { help_cmd; return 0; }
  while :; do
    load_config
    clear 2>/dev/null || true
    if ! is_installed; then
      dash_header
      echo
      if adopt_detect; then
        _menu_item 1 🚚 "Перенести существующий nginx-selfsteal (adopt)"
      else
        _menu_item 1 📥 "Установить"
      fi
      _menu_item 9 🔄 "Обновить скрипт"
      _menu_item 0 🚪 "Выход"
      local c; _menu_prompt c || return 0
      case "$c" in
        1) if adopt_detect; then _menu_run adopt_cmd; else _menu_run install_cmd; fi ;;
        9) _menu_run update_cmd ;;
        0|q|"") return 0 ;;
      esac
      continue
    fi
    dashboard
    _menu_item 1 📊 "Подробный статус"
    _menu_item 2 🌍 "Домены и доступ по IP"
    _menu_item 3 📦 "Приложения (Jitsi, Nextcloud)"
    _menu_item 4 🔐 "Сертификаты"
    _menu_item 5 🔧 "Настройки для Xray / Remnawave"
    _menu_item 6 🧰 "Сервис (перезапуск, логи, обновить nginx)"
    _menu_item 8 🧹 "Удалить"
    _menu_item 9 🔄 "Обновить скрипт"
    _menu_item 0 🚪 "Выход"
    local c; _menu_prompt c || return 0
    case "$c" in
      1) _menu_run status_cmd ;;
      2) _menu_domains ;;
      3) _menu_apps ;;
      4) _menu_certs ;;
      5) _menu_run xray_hint ;;
      6) _menu_service ;;
      8) _menu_run uninstall_cmd ;;
      9) _menu_run update_cmd ;;
      0|q|"") return 0 ;;
    esac
  done
}
