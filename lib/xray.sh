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

# xray_domain_hint DOMAIN [PORT]
xray_domain_hint() {
  local d="$1" p="${2:-$PUBLIC_PORT}"
  printf '\n%sВ Remnawave: inbound на порту %s — добавьте %s в serverNames; его target: %s (xver %s).%s\n' \
    "$C_DIM" "$p" "$d" "$(port_target "$p")" "$([[ "$PROXY_PROTOCOL" == 1 ]] && echo 1 || echo 0)" "$C_RESET"
}

# One realitySettings block per public port: each Xray inbound points to its own nginx listener.
xray_hint() {
  local p names joined n=0
  title "Настройки Reality inbound (Remnawave → Config Profiles)"
  for p in $(site_ports); do
    names="$(list_sites | awk -F@ -v p="$p" '$2 == p { printf "%s\"%s\"", (n++ ? ", " : ""), $1 }')"
    [[ -n "$names" || "$p" == "$PUBLIC_PORT" ]] || continue
    n=$((n+1))
    joined="${names:-\"your.domain\"}"
    printf '\n%sInbound на порту %s%s%s\n' "$C_BOLD" "$p" "$([[ "$p" == "$PUBLIC_PORT" ]] && echo " (основной)")" "$C_RESET"
    cat <<EOF
"realitySettings": {
  "show": false,
  "xver": $( [[ "$PROXY_PROTOCOL" == "1" ]] && echo 1 || echo 0 ),
  "target": "$(port_target "$p")",
  "serverNames": [${joined}],
  "privateKey": "...",
  "shortIds": ["..."]
}
EOF
  done
  printf '\n%sУ каждого публичного порта свой target: так nginx понимает, на какой порт пришёл клиент.\n' "$C_DIM"
  printf 'Изменения в панели делаете сами — скрипт её не трогает.%s\n' "$C_RESET"
}
