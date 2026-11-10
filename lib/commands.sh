# shellcheck shell=bash
# Top-level commands: install, status, logs, restart, down, uninstall, update.

install_cmd() {
  local domain="" page="" upstream="" mode="" tcp_port="" public_port="" email="" no_pp=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) domain="${2:-}"; shift 2;;
      --page) page="${2:-}"; shift 2;;
      --proxy) upstream="${2:-}"; shift 2;;
      --socket) mode="socket"; shift;;
      --tcp) mode="tcp"; shift;;
      --tcp-port) tcp_port="${2:-}"; mode="tcp"; shift 2;;
      --socket-path) SOCKET_PATH="${2:-}"; shift 2;;
      --public-port) public_port="${2:-}"; shift 2;;
      --email) email="${2:-}"; shift 2;;
      --no-proxy-protocol) no_pp=1; shift;;
      -y|--yes) ASSUME_YES=1; shift;;
      *) die "Неизвестная опция: $1 (см. selfsteal-apps help)";;
    esac
  done

  title "Установка selfsteal-apps"
  ensure_docker
  have curl || pkg_install curl || die "curl обязателен."
  have openssl || pkg_install openssl || die "openssl обязателен."

  if adopt_detect && ! is_installed; then
    warn "Найден nginx-selfsteal ($OLD_DIR). Для переноса используйте: selfsteal-apps adopt"
    confirm "Запустить перенос сейчас?" y && { adopt_cmd; return; }
    die "Остановите nginx-selfsteal или выполните adopt."
  fi

  load_config

  if [[ -z "$mode" ]] && is_interactive; then
    local m
    choose m "Как Xray передаёт трафик в nginx?" 1 \
      "Unix-сокет $SOCKET_PATH (рекомендуется)" \
      "TCP 127.0.0.1:PORT"
    [[ "$m" == TCP* ]] && mode="tcp" || mode="socket"
  fi
  LISTEN_MODE="${mode:-$LISTEN_MODE}"
  if [[ "$LISTEN_MODE" == "tcp" ]]; then
    [[ -n "$tcp_port" ]] || ask tcp_port "Локальный TCP-порт nginx" "$TCP_PORT"
    valid_port "$tcp_port" || die "Некорректный порт: $tcp_port"
    TCP_PORT="$tcp_port"
  fi
  [[ "$SOCKET_PATH" == /* ]] || die "Путь сокета должен быть абсолютным."

  [[ -n "$public_port" ]] || ask public_port "Публичный порт Reality inbound" "$PUBLIC_PORT"
  valid_port "$public_port" || die "Некорректный порт: $public_port"
  PUBLIC_PORT="$public_port"
  (( no_pp )) && PROXY_PROTOCOL="0"

  if [[ -z "$email" && -z "$ACME_EMAIL" ]]; then
    ask email "Email для Let's Encrypt (можно пусто)" ""
  fi
  if [[ -n "$email" ]]; then
    valid_email "$email" || die "Некорректный email: $email"
    ACME_EMAIL="$email"
  fi

  PUBLIC_IP="$(detect_public_ip || true)"
  [[ -n "$PUBLIC_IP" ]] && info "Публичный IPv4: $PUBLIC_IP" || warn "Не удалось определить публичный IPv4."

  check_ports_free
  save_config
  _SSA_RECREATE=1 apply_config || die "Не удалось запустить nginx."
  ensure_acme
  check_xray_socket_access

  if [[ -z "$domain" ]] && is_interactive; then
    ask domain "Добавить домен сейчас (пусто — пропустить)" ""
  fi
  if [[ -n "$domain" ]]; then
    local a=("$domain")
    [[ -n "$page" ]] && a+=(--page "$page")
    [[ -n "$upstream" ]] && a+=(--proxy "$upstream")
    domain_add "${a[@]}"
  fi

  log "Установка завершена."
  xray_hint
}

status_cmd() {
  is_installed || { info "selfsteal-apps не установлен. Запустите: selfsteal-apps install"; return 0; }
  title "selfsteal-apps $SSA_VERSION"
  printf ' Режим:          %s\n' "$( [[ $LISTEN_MODE == socket ]] && echo "unix-сокет $SOCKET_PATH" || echo "tcp 127.0.0.1:$TCP_PORT")"
  printf ' proxy_protocol: %s\n' "$( [[ $PROXY_PROTOCOL == 1 ]] && echo "да (xver 1)" || echo "нет (xver 0)")"
  printf ' Публичный порт: %s\n' "$PUBLIC_PORT"
  printf ' IPv4:           %s\n' "${PUBLIC_IP:-?}"
  if container_running; then
    printf ' nginx:          %sработает%s (%s)\n' "$C_GREEN" "$C_RESET" "$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")"
  else
    printf ' nginx:          %sне запущен%s\n' "$C_RED" "$C_RESET"
  fi
  if [[ "$LISTEN_MODE" == "socket" ]]; then
    [[ -S "$SOCKET_PATH" ]] && printf ' Сокет:          %sесть%s\n' "$C_GREEN" "$C_RESET" ||
      printf ' Сокет:          %sнет%s\n' "$C_RED" "$C_RESET"
  fi
  if acme_installed && crontab -l 2>/dev/null | grep -q "$ACME_HOME"; then
    printf ' Автопродление:  %sвключено (cron)%s\n' "$C_GREEN" "$C_RESET"
  else
    printf ' Автопродление:  %sне настроено%s\n' "$C_YELLOW" "$C_RESET"
  fi
  domain_list
  apps_status_brief
}

logs_cmd() {
  is_installed || die "Не установлено."
  docker logs -f --tail "${1:-200}" "$CONTAINER"
}

restart_cmd() { is_installed || die "Не установлено."; acme_migrate_reloadcmd; _SSA_RECREATE=1 apply_config; }

down_cmd() {
  is_installed || die "Не установлено."
  compose down >/dev/null && log "nginx остановлен."
}

cert_cmd() {
  local sub="${1:-}"; shift || true
  is_installed || die "Не установлено."
  case "$sub" in
    status|list|ls|"") cert_list ;;
    issue|reissue)
      local d="${1:-}"
      [[ -n "$d" ]] || { pick_domain d || return 0; }
      domain_exists "$d" || die "Домен $d не найден."
      local n; n="$(domain_cert_name "$d")"
      if is_wildcard_name "$n" && store_has "$n"; then
        [[ "$sub" == issue ]] && { log "$d уже покрыт wildcard *.${n#star.}"; return 0; }
        store_renewed_here "$n" || die "Wildcard *.${n#star.} импортирован — перевыпускайте его там, где он выпущен, или: cert wildcard ${n#star.}"
        wildcard_issue "${n#star.}" --force
        return
      fi
      if [[ "$sub" == reissue ]]; then issue_cert "$d" force || return 1
      else issue_cert "$d" || return 1
      fi
      _set_cert_source "$d" acme
      apply_config
      ;;
    wildcard)
      case "${1:-}" in
        remove|rm|del) shift; wildcard_remove "$@" ;;
        *) wildcard_issue "$@" ;;
      esac
      ;;
    renew) renew_all ;;
    export) cert_export "$@" ;;
    import) cert_import "$@" ;;
    manual)
      local d="${1:-}" crt="${2:-}" key="${3:-}"
      [[ -n "$d" ]] || { pick_domain d || return 0; }
      domain_exists "$d" || die "Домен $d не найден."
      [[ -n "$crt" ]] || ask crt "Путь к fullchain (PEM)"
      [[ -n "$key" ]] || ask key "Путь к приватному ключу (PEM)"
      install_manual_cert "$d" "$crt" "$key"
      _set_cert_source "$d" manual
      apply_config
      ;;
    *) die "cert: list | issue <домен> | reissue <домен> | wildcard <зона|поддомен> [--cf-token T --cf-zone-id ID] | wildcard remove <зона> | export [что] [файл] | import <архив|папка|crt key> | renew";;
  esac
}

domain_cmd() {
  local sub="${1:-}"; shift || true
  is_installed || die "Сначала: selfsteal-apps install"
  case "$sub" in
    list|ls|"") domain_list ;;
    add) domain_add "$@" ;;
    rm|remove|del) domain_remove "$@" ;;
    set) domain_set "$@" ;;
    *) die "domain: list | add <домен> [--page P|--proxy URL] | set <домен> ... | remove <домен>";;
  esac
}

uninstall_cmd() {
  title "Удаление selfsteal-apps"
  warn "Будут удалены: контейнер $CONTAINER, $DATA_DIR, $CONF_DIR (вкл. сертификаты и acme.sh)."
  warn "Xray / remnanode не трогаются. Reality-fallback перестанет отвечать, пока не поставите другой dest."
  confirm "Удалить?" n || return 0
  local a
  for a in $(available_apps); do
    if app_installed "$a"; then
      warn "Установлено приложение $(app_title "$a") — сначала удаляю его."
      "${a}_uninstall"
      app_installed "$a" && die "Удаление прервано: $(app_title "$a") остался установлен."
    fi
  done
  if [[ -f "$NGINX_DIR/docker-compose.yml" ]]; then compose down >/dev/null 2>&1 || true; fi
  if acme_installed; then acme --uninstall >/dev/null 2>&1 || true; fi
  rm -rf "${DATA_DIR:?}" "${CONF_DIR:?}"
  [[ "$LISTEN_MODE" == "socket" ]] && rm -f "$SOCKET_PATH"
  if [[ "${1:-}" == "--purge" ]] || { is_interactive && confirm "Удалить и саму команду selfsteal-apps?" n; }; then
    rm -f "$BIN_LINK"; rm -rf "${SSA_LIB:?}"
    log "Команда удалена."
  fi
  log "selfsteal-apps удалён."
  if adopt_detect; then
    info "Старый nginx-selfsteal можно вернуть: cd $OLD_DIR && docker compose up -d"
  fi
}

update_cmd() {
  info "Обновляю selfsteal-apps из ${SSA_REPO}@${SSA_BRANCH}..."
  local tmp; tmp="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/${SSA_REPO}/${SSA_BRANCH}/install.sh" -o "$tmp" ||
    { rm -f "$tmp"; die "Не удалось скачать install.sh"; }
  SSA_REPO="$SSA_REPO" SSA_BRANCH="$SSA_BRANCH" SSA_NO_LAUNCH=1 bash "$tmp" || { rm -f "$tmp"; die "Обновление не удалось."; }
  rm -f "$tmp"
  if is_installed; then
    # re-exec the new code to re-render configs with possible template fixes
    "$BIN_LINK" restart
  fi
}

version_cmd() {
  printf 'selfsteal-apps %s\n' "$SSA_VERSION"
  printf 'https://github.com/%s\n' "$SSA_REPO"
}

help_cmd() {
  cat <<EOF
${C_BOLD}selfsteal-apps ${SSA_VERSION}${C_RESET} — nginx-маскировка для Xray Reality (selfsteal) с несколькими доменами.

Без аргументов открывается интерактивное меню.

${C_BOLD}Установка${C_RESET}
  install [--socket | --tcp --tcp-port 9443] [--public-port 443]
          [--email you@x.com] [--domain D [--page 403|--proxy URL]] [--yes]
  adopt                         перенести существующий nginx-selfsteal (DigneZzZ)

${C_BOLD}Домены${C_RESET}
  domain list
  domain add <домен> [--page 403|404|502|503|welcome] [--proxy http://127.0.0.1:8000]
                     [--http | --wildcard [--cf-token T --cf-zone-id ID] | --no-cert]
                     (если есть wildcard зоны — он подхватывается сам)
  domain set <домен> --page P | --proxy URL
  domain remove <домен>

${C_BOLD}Приложения${C_RESET}
  app list
  app jitsi install [--domain D] [--auth|--no-auth] [--http-port 8000] [--jvb-port 10000]
  app jitsi status | logs [web|prosody|jicofo|jvb] | update [--force] | restart | uninstall
  app jitsi user list | add <имя> [пароль] | passwd <имя> [пароль] | del <имя>
  app nextcloud install [--domain D] [--admin NAME] [--http-port 8081]
  app nextcloud status | logs [app|db|redis|cron] | update | restart | uninstall
  app nextcloud user list | add <имя> [пароль] | passwd <имя> [пароль] | del <имя>
  app nextcloud occ <аргументы>              любая команда occ

${C_BOLD}Сертификаты${C_RESET}
  cert list                                  все сертификаты и какие домены их используют
  cert issue <домен> | reissue <домен>       отдельный сертификат (http-01) / перевыпуск
  cert wildcard <зона или поддомен> [--cf-token T] [--cf-zone-id ID]
                                             *.зона + зона через Cloudflare DNS-01, автопродление
  cert wildcard remove <зона>
  cert export [домен|зона] [файл.tar.gz]     выгрузить для переноса на другую ноду
  cert import <архив.tar.gz | папка | fullchain.pem privkey.pem>
                                             имена определяются из сертификата сами
  cert renew                                 продлить всё, у чего подходит срок

${C_BOLD}Сервис${C_RESET}
  status | logs [N] | restart | down | xray | update | version | uninstall
EOF
}
