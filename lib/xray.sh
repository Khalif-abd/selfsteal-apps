# shellcheck shell=bash
# Xray / Remnawave node side: /dev/shm mount check and config hints.
# The /dev/shm detection approach is adapted from DigneZzZ/remnawave-scripts
# (selfsteal.sh, MIT License).

_container_has_shm() {
  docker inspect "$1" --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' 2>/dev/null |
    grep -q '/dev/shm:/dev/shm'
}

_detect_node_compose() {
  local p
  for p in /opt/remnanode /root/remnanode; do
    [[ -f "$p/docker-compose.yml" ]] && { echo "$p/docker-compose.yml"; return 0; }
  done
  # ask docker where the container's compose project lives
  local wd
  wd="$(docker inspect remnanode --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)"
  [[ -n "$wd" && -f "$wd/docker-compose.yml" ]] && { echo "$wd/docker-compose.yml"; return 0; }
  return 1
}

_add_shm_to_compose() {
  local f="$1" bak
  bak="$f.bak.$(ts)"
  cp -a "$f" "$bak"
  if grep -qE '^[[:space:]]*#[[:space:]]*-[[:space:]]*/dev/shm:/dev/shm' "$f"; then
    sed -i -E 's|^([[:space:]]*)#[[:space:]]*volumes:|\1volumes:|' "$f"
    sed -i -E 's|^[[:space:]]*#[[:space:]]*(-[[:space:]]*/dev/shm:/dev/shm.*)|      \1|' "$f"
  elif grep -qE '^[[:space:]]+volumes:' "$f"; then
    sed -i -E '0,/^[[:space:]]+volumes:/s||&\n      - /dev/shm:/dev/shm|' "$f"
  elif grep -qE '^[[:space:]]+network_mode:' "$f"; then
    sed -i -E '0,/^([[:space:]]+)network_mode:/s//\1volumes:\n\1  - \/dev\/shm:\/dev\/shm\n&/' "$f"
  else
    warn "Не нашёл, куда вставить volume — добавьте вручную: - /dev/shm:/dev/shm"
    rm -f "$bak"; return 1
  fi
  if docker compose -f "$f" config >/dev/null 2>&1; then
    log "Добавил /dev/shm в $f (бэкап: $bak)"
  else
    mv -f "$bak" "$f"
    err "Compose-файл после правки невалиден — вернул как было."
    return 1
  fi
}

# Socket mode needs Xray's container to see /dev/shm.
check_xray_socket_access() {
  [[ "$LISTEN_MODE" == "socket" ]] || return 0
  local c found=0
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(remnanode|xray|marzban-node)' || true); do
    found=1
    if _container_has_shm "$c"; then
      log "$c видит /dev/shm — сокет доступен Xray."
      continue
    fi
    warn "Контейнер $c не монтирует /dev/shm — Xray не увидит $SOCKET_PATH."
    local f
    if f="$(_detect_node_compose)"; then
      if confirm "Добавить '- /dev/shm:/dev/shm' в $f и перезапустить $c?" y; then
        _add_shm_to_compose "$f" && (cd "$(dirname "$f")" && docker compose up -d) && log "$c перезапущен."
      fi
    else
      info "Добавьте в volumes контейнера $c:  - /dev/shm:/dev/shm  и перезапустите его."
    fi
  done
  (( found )) || info "Контейнер Xray/remnanode не найден. Если Xray в Docker — смонтируйте /dev/shm:/dev/shm."
}

# remnawave_block PORT [DOMAIN] — what must be in the Xray inbound on PORT, plus a checklist.
remnawave_block() {
  local p="$1" d="${2:-}" names joined xv bar
  xv="$([[ "$PROXY_PROTOCOL" == 1 ]] && echo 1 || echo 0)"
  names="$(list_sites | awk -F@ -v p="$p" '$2 == p { printf "%s\"%s\"", (n++ ? ", " : ""), $1 }')"
  joined="${names:-\"${d:-your.domain}\"}"
  bar="${C_YELLOW}│${C_RESET}"
  printf '\n%s┌ Что сделать в Remnawave — inbound на порту %s%s\n' "$C_YELLOW$C_BOLD" "$p" "$C_RESET"
  printf '%s %s"realitySettings": {%s\n' "$bar" "$C_BOLD" "$C_RESET"
  printf '%s   "xver": %s,\n' "$bar" "$xv"
  printf '%s   "target": "%s%s%s",\n' "$bar" "$C_BOLD" "$(port_target "$p")" "$C_RESET"
  printf '%s   "serverNames": [%s], ...\n' "$bar" "$joined"
  printf '%s }\n' "$bar"
  printf '%s %sПроверьте:%s\n' "$bar" "$C_BOLD" "$C_RESET"
  printf '%s  • "port" у inbound = %s, "security": "reality"\n' "$bar" "$p"
  printf '%s  • target ровно %s — у каждого порта свой; чужой target откроет не тот сайт\n' "$bar" "$(port_target "$p")"
  printf '%s  • "xver": %s — иначе сайт не откроется\n' "$bar" "$xv"
  [[ -n "$d" ]] && printf '%s  • %s есть в serverNames\n' "$bar" "$d"
  printf '%s  • inbound включён в профиль, выбранный для этой ноды (Nodes → нода → профиль и inbounds)\n' "$bar"
  if [[ "$LISTEN_MODE" == socket ]]; then
    printf '%s  • у remnanode смонтирован /dev/shm:/dev/shm (после добавления — docker compose up -d --force-recreate)\n' "$bar"
  fi
  printf '%s  • TCP/%s открыт снаружи (файрвол хостера%s)\n' "$bar" "$p" "$(_ufw_port_note "$p")"
  if [[ -n "$d" ]]; then
    local ip; ip="$(domain_server_ip "$d" || true)"
    if [[ -n "$ip" ]]; then printf '%s  • DNS: %s → %s (IP этого сервера) ✓\n' "$bar" "$d" "$ip"
    else printf '%s  • DNS: A-запись %s должна указывать на IP этого сервера: %s\n' "$bar" "$d" "$(server_ipv4s | paste -sd' ' - | sed 's/ /, /g')"; fi
  fi
  printf '%s└ Проверить потом: selfsteal-apps doctor (меню «Сервис» → «Диагностика»)%s\n' "$C_YELLOW" "$C_RESET"
}

# ufw active and the port not allowed -> hint.
_ufw_port_note() {
  have ufw || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  ufw status 2>/dev/null | grep -qE "^$1(/tcp)?[[:space:]]+ALLOW" && { printf ', ufw: открыт'; return 0; }
  printf ', ufw: НЕ открыт — ufw allow %s/tcp' "$1"
}

# xray_domain_hint DOMAIN [PORT]
xray_domain_hint() { remnawave_block "${2:-$PUBLIC_PORT}" "$1"; }

# All inbounds: one block per public port that has domains (and the main one).
xray_hint() {
  local p
  title "Настройки Reality inbound (Remnawave → Config Profiles)"
  printf '%sУ каждого публичного порта свой target: так nginx понимает, на какой порт пришёл клиент.\n' "$C_DIM"
  printf 'Изменения в панели делаете сами — скрипт её не трогает.%s\n' "$C_RESET"
  for p in $(site_ports); do
    [[ -n "$(list_sites | awk -F@ -v p="$p" '$2 == p')" || "$p" == "$PUBLIC_PORT" ]] || continue
    remnawave_block "$p"
  done
}

# xray_moved_hint OLD_SITE NEW_SITE — what to change in Remnawave after a port move.
xray_moved_hint() {
  local o="$1" n="$2" d op
  d="$(site_domain "$n")"; op="$(site_port "$o")"
  remnawave_block "$(site_port "$n")" "$d"
  if [[ -z "$(list_sites | awk -F@ -v d="$d" -v p="$op" '$1 == d && $2 == p')" ]]; then
    printf '%s  И в inbound на порту %s уберите %s из serverNames.%s\n' "$C_YELLOW" "$op" "$d" "$C_RESET"
  fi
}

# Running Xray containers (remnanode, xray, marzban-node).
xray_containers() { docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(remnanode|xray|marzban-node)' || true; }

# Socket problems as seen from Xray containers: "<container>\t<path>\t<reason>"
#   no-shm   — the container does not mount /dev/shm (sees its own empty one)
#   not-seen — mounted, but the socket is not visible inside (container created before the mount)
xray_socket_problems() {
  [[ "$LISTEN_MODE" == "socket" ]] || return 0
  local c s
  for c in $(xray_containers); do
    if ! _container_has_shm "$c"; then printf '%s\t%s\tno-shm\n' "$c" "$(dirname "$SOCKET_PATH")"; continue; fi
    while read -r s; do
      [[ -n "$s" && -S "$s" ]] || continue
      docker exec "$c" test -S "$s" 2>/dev/null || printf '%s\t%s\tnot-seen\n' "$c" "$s"
    done < <(socket_paths)
  done
}

# Re-create the Xray container from its compose file (applies volumes). Interrupts VPN for a few seconds.
xray_recreate() {
  local c="$1" f
  f="$(_detect_node_compose)" || { warn "Не нашёл docker-compose.yml для $c — пересоздайте его вручную: docker compose up -d --force-recreate"; return 1; }
  ( cd "$(dirname "$f")" && docker compose up -d --force-recreate ) >/dev/null 2>&1 && log "$c пересоздан." ||
    { err "Не удалось пересоздать $c."; return 1; }
}
