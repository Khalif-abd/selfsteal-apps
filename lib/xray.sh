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

xray_domain_hint() {
  local d="$1"
  printf '\n%sВ Remnawave (профиль ноды, realitySettings) добавьте домен в serverNames:%s %s\n' "$C_DIM" "$C_RESET" "$d"
}

xray_hint() {
  local names=() d
  for d in $(list_domains); do names+=("\"$d\""); done
  local joined; joined="$(IFS=,; echo "${names[*]:-\"your.domain\"}")"
  joined="${joined//,/, }"
  title "Настройки Reality inbound (Remnawave → Config Profiles)"
  cat <<EOF
"realitySettings": {
  "show": false,
  "xver": $( [[ "$PROXY_PROTOCOL" == "1" ]] && echo 1 || echo 0 ),
  "target": "$(xray_target)",
  "serverNames": [${joined}],
  "privateKey": "...",
  "shortIds": ["..."]
}
EOF
  printf '\n%sПубличный порт inbound: %s. Изменения в панели делаете сами — скрипт её не трогает.%s\n' "$C_DIM" "$PUBLIC_PORT" "$C_RESET"
}
