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
    domain_list
    echo
    printf '  1) Выпустить сертификат (если нет)\n  2) Перевыпустить принудительно\n  3) Продлить все, у которых подходит срок\n  4) Установить свой сертификат из файлов\n  0) Назад\n\n'
    local c; read -r -p "Выбор: " c || return 0
    case "$c" in
      1) _menu_run cert_cmd issue ;;
      2) _menu_run cert_cmd reissue ;;
      3) _menu_run cert_cmd renew ;;
      4) _menu_run cert_cmd manual ;;
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
    printf '  1) Статус\n  2) Домены\n  3) Сертификаты\n  4) Настройки для Xray / Remnawave\n  5) Сервис (перезапуск, логи)\n  8) Удалить\n  9) Обновить скрипт\n  0) Выход\n\n'
    local c; read -r -p "Выбор: " c || return 0
    case "$c" in
      1) _menu_run status_cmd ;;
      2) _menu_domains ;;
      3) _menu_certs ;;
      4) _menu_run xray_hint ;;
      5) _menu_service ;;
      8) _menu_run uninstall_cmd ;;
      9) _menu_run update_cmd ;;
      0|q|"") return 0 ;;
    esac
  done
}
