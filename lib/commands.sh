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
  doctor_preflight

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

  [[ -n "$public_port" ]] || ask public_port "Основной публичный порт (порт Xray inbound)" "$PUBLIC_PORT"
  valid_public_port "$public_port" || die "Некорректный порт: $public_port (1-65535, не 80)"
  if [[ "$public_port" != "$PUBLIC_PORT" && -n "$(list_sites)" ]]; then
    die "Основной порт сейчас $PUBLIC_PORT и на нём есть домены — менять его нельзя. Домен на другом порту: selfsteal-apps domain add <домен> --port $public_port"
  fi
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
  printf ' Режим:          %s\n' "$( [[ $LISTEN_MODE == socket ]] && echo "unix-сокеты" || echo "tcp 127.0.0.1")"
  printf ' proxy_protocol: %s\n' "$( [[ $PROXY_PROTOCOL == 1 ]] && echo "да (xver 1)" || echo "нет (xver 0)")"
  local lp
  for lp in $(site_ports); do
    printf ' Порт %-9s Xray target: %s%s\n' "$lp:" "$(port_target "$lp")" "$([[ "$lp" == "$PUBLIC_PORT" ]] && echo "  (основной)")"
  done
  printf ' IPv4:           %s\n' "${PUBLIC_IP:-?}"
  if container_running; then
    printf ' nginx:          %sработает%s, версия %s (%s)\n' "$C_GREEN" "$C_RESET" "$(nginx_version || true)" "$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")"
  else
    printf ' nginx:          %sне запущен%s\n' "$C_RED" "$C_RESET"
  fi
  if [[ "$LISTEN_MODE" == "socket" ]]; then
    local sp
    while read -r sp; do
      [[ -n "$sp" ]] || continue
      [[ -S "$sp" ]] && printf ' Сокет:          %sесть%s %s\n' "$C_GREEN" "$C_RESET" "$sp" ||
        printf ' Сокет:          %sнет%s %s\n' "$C_RED" "$C_RESET" "$sp"
    done < <(socket_paths)
  fi
  if acme_installed && crontab -l 2>/dev/null | grep -q "$ACME_HOME"; then
    printf ' Автопродление:  %sвключено (cron)%s\n' "$C_GREEN" "$C_RESET"
  else
    printf ' Автопродление:  %sне настроено%s\n' "$C_YELLOW" "$C_RESET"
  fi
  ip_status
  local prob; prob="$(doctor_brief)"
  [[ -n "$prob" ]] && printf ' %sВнимание:       %s%s — selfsteal-apps doctor\n' "$C_RED" "$prob" "$C_RESET"
  domain_list
  apps_status_brief
}

# ip [status | on [домен] [--port P] | off] — show a site on https://<IP>:<port> (and unknown SNI) or reject.
ip_cmd() {
  is_installed || die "Не установлено."
  local sub="${1:-status}"; shift || true
  local d="" p="" sid=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) p="${2:-}"; shift 2;;
      *) d="$(lower "$1")"; shift;;
    esac
  done
  case "$sub" in
    status|"") ip_status ;;
    on|enable)
      if [[ -n "$d" ]]; then
        pick_site sid "$d" "$p" || return 0
      else
        local ss=() labels=() x c i
        for x in $(list_sites); do has_cert "$(site_domain "$x")" && ss+=("$x"); done
        (( ${#ss[@]} )) || die "Нет доменов с сертификатом — показывать по IP нечего."
        if (( ${#ss[@]} == 1 )) || ! is_interactive; then sid="${ss[0]}"
        else
          for x in "${ss[@]}"; do labels+=("$(site_label "$x")"); done
          choose c "Какой сайт показывать по IP" 1 "${labels[@]}"
          for i in "${!labels[@]}"; do [[ "${labels[$i]}" == "$c" ]] && sid="${ss[$i]}"; done
        fi
      fi
      site_exists "$sid" || die "Сайт не найден."
      has_cert "$(site_domain "$sid")" || die "У $(site_domain "$sid") нет сертификата — сначала выпустите его."
      IP_ACCESS=1; IP_DOMAIN="$sid"; save_config
      apply_config || die "Не удалось применить конфиг."
      log "По $(public_url "${PUBLIC_IP:-<IP>}" "$(site_port "$sid")") теперь открывается $(site_label "$sid") (браузер предупредит о сертификате — это нормально)."
      ;;
    off|disable)
      IP_ACCESS=0; save_config
      apply_config || die "Не удалось применить конфиг."
      log "Доступ по IP выключен: TLS-соединения без известного домена обрываются."
      ;;
    *) die "Использование: selfsteal-apps ip [status | on [домен] [--port P] | off]" ;;
  esac
}

ip_status() {
  local s
  if s="$(ip_access_site)"; then
    printf ' Доступ по IP:   %sвключён%s — %s открывает сайт %s\n' "$C_GREEN" "$C_RESET" \
      "$(public_url "${PUBLIC_IP:-<IP>}" "$(site_port "$s")")" "$(site_label "$s")"
  elif [[ "${IP_ACCESS:-0}" == "1" ]]; then
    printf ' Доступ по IP:   %sвключён, но нет домена с сертификатом%s — соединения обрываются\n' "$C_YELLOW" "$C_RESET"
  else
    printf ' Доступ по IP:   выключен — на https://%s соединение обрывается, сайт не видно\n' "${PUBLIC_IP:-<IP>}"
  fi
}

logs_cmd() {
  is_installed || die "Не установлено."
  docker logs -f --tail "${1:-200}" "$CONTAINER"
}

restart_cmd() { is_installed || die "Не установлено."; acme_migrate_reloadcmd; _SSA_RECREATE=1 apply_config; }

# Re-render configs and reload nginx gracefully; recreates the container only if docker-compose.yml changed.
apply_cmd() { is_installed || die "Не установлено."; acme_migrate_reloadcmd; apply_config; }

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
    *) die "domain: list | add <домен> [--port P] [--page P|--proxy URL] | set <домен> [--port P] ... | remove <домен> [--port P]";;
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
  local socks; socks="$(socket_paths)"
  rm -rf "${DATA_DIR:?}" "${CONF_DIR:?}"
  local sp; while read -r sp; do [[ -n "$sp" ]] && rm -f "$sp"; done <<<"$socks"
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
    # re-exec the new code: re-render configs with possible template fixes and reload nginx gracefully
    # (no container restart unless docker-compose.yml changed; the nginx image is not touched)
    "$BIN_LINK" apply
  fi
}

# nginx update — pull a fresh $NGINX_IMAGE (security fixes), test the config on it, recreate.
# Separate from the script 'update' on purpose; plain 'restart' never pulls either.
nginx_update_cmd() {
  is_installed || die "Не установлено."
  local old_v new_v running fresh
  old_v="$(container_running && nginx_version || true)"
  running="$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true)"

  info "Скачиваю свежий образ $NGINX_IMAGE..."
  docker pull -q "$NGINX_IMAGE" >/dev/null 2>&1 ||
    die "Не удалось скачать $NGINX_IMAGE (нет доступа к Docker Hub?). Текущий nginx не тронут."

  fresh="$(docker image inspect -f '{{.Id}}' "$NGINX_IMAGE" 2>/dev/null || true)"

  if [[ -n "$fresh" && "$fresh" == "$running" ]] && container_running; then
    log "nginx ${old_v:-?} — это уже последняя версия в $NGINX_IMAGE."
    return 0
  fi

  new_v="$(docker run --rm --network none "$NGINX_IMAGE" nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p' | head -1 || true)"
  info "Новая версия: nginx ${old_v:-?} → ${new_v:-?}. Проверяю конфиг на новом образе..."
  if ! _SSA_TEST_IMAGE=1 restart_cmd; then
    die "Конфиг не прошёл проверку на nginx ${new_v:-?} — работающий nginx не тронут. Пришлите вывод выше разработчику."
  fi
  log "nginx обновлён: ${old_v:-?} → $(nginx_version || echo "${new_v:-?}")."
}

# nginx [version | update]
nginx_cmd() {
  local sub="${1:-version}"; shift || true
  case "$sub" in
    version|status) is_installed || die "Не установлено."
                    printf 'nginx %s (%s)\n' "$(container_running && nginx_version || echo 'не запущен')" "$NGINX_IMAGE" ;;
    update|upgrade) nginx_update_cmd "$@" ;;
    *) die "Использование: selfsteal-apps nginx [version | update]" ;;
  esac
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
  install [--socket | --tcp --tcp-port 9443] [--public-port 443]   (основной порт Xray inbound)
          [--email you@x.com] [--domain D [--page 403|--proxy URL]] [--yes]
  adopt                         перенести существующий nginx-selfsteal (DigneZzZ)

${C_BOLD}Домены${C_RESET}
  domain list
  domain add <домен> [--port P] [--page 403|404|502|503|welcome] [--proxy http://127.0.0.1:8000]
                     --port: публичный порт (порт Xray inbound), по умолчанию основной; один домен
                     может жить на нескольких портах с разным содержимым
                     [--http | --wildcard [--cf-token T --cf-zone-id ID] | --no-cert]
                     (если есть wildcard зоны — он подхватывается сам)
  domain set <домен> [--port P] --page P | --proxy URL
  domain remove <домен> [--port P]
  ip [status | on [домен] [--port P] | off] показывать сайт по https://<IP> (по умолчанию выкл — соединение обрывается)

${C_BOLD}Приложения${C_RESET}
  app list
  app jitsi install [--domain D] [--port P] [--auth|--no-auth] [--http-port 8000] [--jvb-port 10000]
  app jitsi status | logs [web|prosody|jicofo|jvb] | update [--force] | restart | uninstall
  app jitsi user list | add <имя> [пароль] | passwd <имя> [пароль] | del <имя>
  app nextcloud install [--domain D] [--port P] [--admin NAME] [--http-port 8081]
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
  status | logs [N] | down | xray | version | uninstall
  apply                                      пересобрать конфиг и перечитать его без перезапуска nginx
  restart                                    пересобрать конфиг и пересоздать контейнер nginx
  update                                     обновить скрипт (nginx не трогает)
  nginx version | update                     версия nginx / скачать свежий образ nginx и пересоздать
  doctor [--fix]                             диагностика: NAT-перенаправления 443, старые задания cron, порты
EOF
}
