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
  printf '%s selfsteal-apps %s%s  %s\n' "$C_BOLD$C_CYAN" "$SSA_VERSION" "$C_RESET" \
    "$(is_installed && { container_running && printf '%s● nginx работает%s' "$C_GREEN" "$C_RESET" || printf '%s● nginx остановлен%s' "$C_RED" "$C_RESET"; } || printf '%s● не установлено%s' "$C_YELLOW" "$C_RESET")"
  hr
}

_menu_domains() {
  while :; do
    _menu_header
    domain_list
    echo
    printf '  1) Добавить домен\n  2) Изменить содержимое домена\n  3) Удалить домен\n  0) Назад\n\n'
    local c; read -r -p "Выбор: " c || return 0
    case "$c" in
      1) _menu_run domain_add ;;
      2) _menu_run domain_set ;;
      3) _menu_run domain_remove ;;
      0|"") return 0 ;;
    esac
  done
}

_menu_certs() {
  while :; do
    _menu_header
    cert_list
    echo
    printf '  1) Wildcard через Cloudflare (*.зона + зона)\n  2) Отдельный сертификат для домена (http-01)\n  3) Перевыпустить принудительно\n  4) Экспорт — для переноса на другую ноду\n  5) Импорт — архив/папка/файлы с другой ноды\n  6) Продлить все, у которых подходит срок\n  7) Удалить wildcard\n  0) Назад\n\n'
    local c; read -r -p "Выбор: " c || return 0
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
    printf '  1) Перезапустить nginx (пересоздать конфиг)\n  2) Остановить nginx\n  3) Логи nginx (Ctrl+C — выход)\n  4) Проверить доступ Xray к сокету\n  0) Назад\n\n'
    local c; read -r -p "Выбор: " c || return 0
    case "$c" in
      1) _menu_run restart_cmd ;;
      2) _menu_run down_cmd ;;
      3) ( logs_cmd 100 ) || true ;;
      4) _menu_run check_xray_socket_access ;;
      0|"") return 0 ;;
    esac
  done
}

_menu_app() {
  local a="$1"
  while :; do
    _menu_header
    ( "${a}_status" ) 2>/dev/null || true
    echo
    if app_installed "$a"; then
      printf '  1) Переустановить / изменить настройки\n  2) Обновить до последней стабильной версии\n  3) Логи (Ctrl+C — выход)\n  4) Удалить\n'
      app_has "$a" menu_extra && "${a}_menu_extra"
    else
      printf '  1) Установить\n'
    fi
    printf '  0) Назад\n\n'
    local c; read -r -p "Выбор: " c || return 0
    case "$c" in
      0|"") return 0 ;;
      1) _menu_run "${a}_install" ;;
      2) app_installed "$a" && _menu_run "${a}_update" ;;
      3) app_installed "$a" && { ( "${a}_logs" ) || true; } ;;
      4) app_installed "$a" && _menu_run "${a}_uninstall" ;;
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
    for a in "${apps[@]}"; do printf '  %d) %s\n' "$i" "$(app_title "$a")"; i=$((i+1)); done
    printf '  0) Назад\n\n'
    local c; read -r -p "Выбор: " c || return 0
    [[ "$c" == 0 || -z "$c" ]] && return 0
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#apps[@]} )); then
      _menu_app "${apps[$((c-1))]}"
    fi
  done
}

main_menu() {
  is_interactive || { help_cmd; return 0; }
  while :; do
    _menu_header
    if ! is_installed; then
      if adopt_detect; then
        printf '  1) Перенести существующий nginx-selfsteal (adopt)\n'
      else
        printf '  1) Установить\n'
      fi
      printf '  9) Обновить скрипт\n  0) Выход\n\n'
      local c; read -r -p "Выбор: " c || return 0
      case "$c" in
        1) if adopt_detect; then _menu_run adopt_cmd; else _menu_run install_cmd; fi ;;
        9) _menu_run update_cmd ;;
        0|q|"") return 0 ;;
      esac
      continue
    fi
    printf '  1) Статус\n  2) Домены\n  3) Приложения (Jitsi, ...)\n  4) Сертификаты\n  5) Настройки для Xray / Remnawave\n  6) Сервис (перезапуск, логи)\n  8) Удалить\n  9) Обновить скрипт\n  0) Выход\n\n'
    local c; read -r -p "Выбор: " c || return 0
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
