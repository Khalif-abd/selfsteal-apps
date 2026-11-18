# shellcheck shell=bash
# Diagnostics for leftovers of other selfsteal installers that break Xray inbounds.
#
# DigneZzZ selfsteal (nginx) renews certs via TLS-ALPN on a side port (8443/9443/...): its nightly
# cron wrapper /opt/nginx-selfsteal/acme-renew.sh adds "iptables -t nat ... --dport 443 -j REDIRECT
# --to-port <port>", runs acme.sh, then deletes the rules. The wrapper has "set -e", so when acme.sh
# fails (e.g. nothing listens on that port any more) it exits before the cleanup and the REDIRECT
# stays: TCP/443 goes to another port, the 443 inbound never sees it. Renewal is attempted only when
# a cert is due, which is why it comes back every ~2 months.
#
# A node may run several inbounds (443, 444, 8443, 9443, ...), so the ports Xray listens on are taken
# from the system, and every redirect is judged by where it takes traffic from and to:
#   from an Xray port (to anywhere, even another inbound)  -> breaks that inbound      (bad)
#   from 443 to a port nobody listens on (Xray not on 443) -> dead leftover, harmless  (warn)
#   from elsewhere into an Xray port                       -> deliberate, left alone   (shown)
#   anything else                                          -> not ours, not shown
#
# selfsteal-apps itself never touches NAT (http-01 on :80 and dns-01 only).
# Nothing here deletes anything without confirmation (or an explicit --fix).

XRAY_PROCS="${SSA_XRAY_PROCS:-rw-core|xray}"

# TCP ports Xray listens on, from ss (one per line).
xray_ports() {
  ss -Hltnp 2>/dev/null | awk -v re="users:\\\\(\\\\(\"(${XRAY_PROCS})\"" '
    $0 ~ re { n = split($4, a, ":"); if (a[n] ~ /^[0-9]+$/) print a[n] }' | sort -un || true
}

# Xray ports, or PUBLIC_PORT when Xray is not visible (e.g. in docker behind docker-proxy).
doctor_xray_ports() {
  local p; p="$(xray_ports)"
  if [[ -n "$p" ]]; then printf '%s\n' "$p"; else site_ports; fi
}

# All NAT redirects with a single destination port, normalized:
#   kind<TAB>loc<TAB>dport<TAB>to<TAB>rule
#   kind: iptables | ip6tables | nft ; loc: nft "family table chain handle" or "-"
#   to:   local port number, or "ext:<host:port>" for DNAT to another address
# Docker's own chains (DOCKER*) and iptables-nft tables seen through nft are skipped.
nat_rules() {
  local cmd
  for cmd in iptables ip6tables; do
    have "$cmd" || continue
    "$cmd" -t nat -S 2>/dev/null | grep -E -- '-j (REDIRECT|DNAT)' | grep -vE '^-A DOCKER' |
      awk -v k="$cmd" '{
        dp = ""; to = ""
        for (i = 1; i <= NF; i++) {
          if ($i == "--dport") dp = $(i+1)
          if ($i == "--to-ports") { to = $(i+1); sub(/-.*/, "", to) }
          if ($i == "--to-destination") { d = $(i+1)
            if (d ~ /^127\.0\.0\.1:[0-9]+$/) { sub(/.*:/, "", d); to = d } else to = "ext:" d }
        }
        if (dp ~ /^[0-9]+$/) { if (to == "") to = dp; printf "%s\t-\t%s\t%s\t%s\n", k, dp, to, $0 }
      }' || true
  done
  have nft || return 0
  nft -a list ruleset 2>/dev/null | awk '
    $1 == "table" { fam = $2; tbl = $3 }
    $1 == "chain" { ch = $2 }
    /(redirect|dnat)/ && match($0, /dport [0-9]+([^0-9-]|$)/) && match($0, /# handle [0-9]+/) {
      if (tbl == "nat" && (fam == "ip" || fam == "ip6")) next
      h = substr($0, RSTART + 9, RLENGTH - 9)
      r = $0; sub(/[ \t]*# handle.*/, "", r); gsub(/^[ \t]+/, "", r)
      match(r, /dport [0-9]+/); dp = substr(r, RSTART + 6, RLENGTH - 6)
      to = dp
      if (match(r, /redirect to :[0-9]+/)) to = substr(r, RSTART + 13, RLENGTH - 13)
      else if (match(r, /dnat( ip| ip6)? to [^ ]+/)) { d = substr(r, RSTART, RLENGTH); sub(/.* to /, "", d); to = "ext:" d }
      printf "nft\t%s %s %s %s\t%s\t%s\t%s\n", fam, tbl, ch, h, dp, to, r
    }' || true
}

# Classify nat_rules against Xray ports: prints "class<TAB>record" (class: bad | warn | info).
nat_classify() {
  local xp kind loc dp to rule
  xp=" $(doctor_xray_ports | tr '\n' ' ') "
  while IFS=$'\t' read -r kind loc dp to rule; do
    [[ -n "$dp" ]] || continue
    if [[ "$xp" == *" $dp "* ]]; then
      [[ "$to" == "$dp" ]] && continue          # same port, nothing changes
      printf 'bad\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$loc" "$dp" "$to" "$rule"
    elif [[ "$to" != ext:* && "$xp" == *" $to "* ]]; then
      printf 'info\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$loc" "$dp" "$to" "$rule"
    elif [[ "$dp" == 443 && "$to" != ext:* ]] && ! port_in_use_tcp "$to"; then
      printf 'warn\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$loc" "$dp" "$to" "$rule"
    fi
  done < <(nat_rules | sort -u)
}

# Active cron lines of other installers that add those NAT rules.
old_renew_jobs() {
  have crontab || return 0
  crontab -l 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -E 'acme-renew\.sh' || true
}

# Our acme.sh renewal job present? (DigneZzZ setup deletes every crontab line containing "acme")
our_cron_ok() { ! acme_installed || crontab -l 2>/dev/null | grep -q "$ACME_HOME"; }

# One-line problem summary for the main screen; empty when all is fine.
doctor_brief() {
  local sp
  sp="$(socket_problems | head -1)"
  if [[ -n "$sp" ]]; then
    printf 'Xray не может подключиться к nginx: нет сокета %s — нужен перезапуск nginx' "$(cut -f1 <<<"$sp")"; return 0
  fi
  local c
  if is_installed && [[ "$LISTEN_MODE" == socket ]]; then
    for c in $(xray_containers); do
      _container_has_shm "$c" || { printf '%s не монтирует /dev/shm — Xray не видит сокеты nginx' "$c"; return 0; }
    done
  fi
  local bad ports
  bad="$(nat_classify | awk -F'\t' '$1 == "bad" { print $4 }' | sort -un | paste -sd, -)"
  if [[ -n "$bad" ]]; then
    printf 'NAT уводит трафик с порта Xray %s — эти inbound не работают' "$bad"; return 0
  fi
  [[ -n "$(old_renew_jobs)" ]] && printf 'в cron осталось продление старого selfsteal (ставит NAT на 443)'
  return 0
}

_doc_ok()   { printf '  %s %s\n' "$(dot ok)" "$*"; }
_doc_bad()  { printf '  %s %s\n' "$(dot bad)" "$*"; }
_doc_warn() { printf '  %s %s\n' "$(dot warn)" "$*"; }

_doc_target() { if [[ "$1" == ext:* ]]; then printf '%s' "${1#ext:}"; else printf ':%s' "$1"; fi; }

# Delete records "kind<TAB>loc<TAB>dport<TAB>to<TAB>rule" from stdin.
_doc_delete() {
  local kind loc dp to rule args fam tbl ch h
  while IFS=$'\t' read -r kind loc dp to rule; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" == nft ]]; then
      read -r fam tbl ch h <<<"$loc"
      if nft delete rule "$fam" "$tbl" "$ch" handle "$h" 2>/dev/null; then log "Удалено (nft): $rule"
      else warn "Не удалось удалить: nft delete rule $fam $tbl $ch handle $h"; fi
      continue
    fi
    if [[ "$rule" == *\"* || "$rule" == *\'* ]]; then
      warn "Правило с комментарием — удалите вручную: $kind -t nat ${rule/#-A/-D}"; continue
    fi
    read -r -a args <<<"${rule/#-A/-D}"
    if "$kind" -t nat "${args[@]}" 2>/dev/null; then log "Удалено: $kind -t nat $rule"
    else warn "Не удалось удалить: $kind -t nat $rule"; fi
  done
}

_doc_fix_cron() {
  local cur; cur="$(crontab -l 2>/dev/null || true)"
  install -d -m 700 "$CONF_DIR"
  printf '%s\n' "$cur" > "$CONF_DIR/crontab.bak.$(ts)"
  printf '%s\n' "$cur" | sed -E 's|^([^#].*acme-renew\.sh.*)$|# disabled by selfsteal-apps: \1|' | crontab -
  log "Задания acme-renew.sh в cron отключены (закомментированы, копия crontab — в $CONF_DIR)."
}

# Print the problems; with fixes=1 offer to fix each group (asks unless --fix/--yes).
# Returns 1 if redirects away from Xray ports are still in place.
doctor_check() {
  local fixes="${1:-0}" cls bad warn info jobs p owner xp src
  cls="$(nat_classify)"
  bad="$(awk -F'\t' '$1 == "bad"' <<<"$cls" | cut -f2-)"
  warn="$(awk -F'\t' '$1 == "warn"' <<<"$cls" | cut -f2-)"
  info="$(awk -F'\t' '$1 == "info"' <<<"$cls" | cut -f2-)"
  jobs="$(old_renew_jobs)"
  xp="$(xray_ports | paste -sd' ' -)"
  if [[ -n "$xp" ]]; then src="Xray слушает: ${xp// /, }"
  else src="Xray не найден среди процессов — проверяю порты сайтов: $(site_ports | paste -sd, -)"; fi

  printf '\n %s%sNAT-перенаправления%s  %s(%s)%s\n' "$C_BOLD" "$(ic 🔀)" "$C_RESET" "$C_DIM" "$src" "$C_RESET"
  local kind loc dp to rule
  if [[ -z "$bad" ]]; then
    _doc_ok "с портов Xray ничего не уводится"
  else
    _doc_bad "${C_RED}трафик уводится с портов Xray — эти inbound не работают:${C_RESET}"
    while IFS=$'\t' read -r kind loc dp to rule; do
      printf '      %s → %s   %s%s%s\n' "$dp" "$(_doc_target "$to")" "$C_DIM" "$rule" "$C_RESET"
    done <<<"$bad"
    printf '    %sОбычно это остаток продления сертификатов старого selfsteal (DigneZzZ).%s\n' "$C_DIM" "$C_RESET"
    if (( fixes )) && confirm "Удалить эти правила? Docker и остальные правила не затрагиваются" y; then
      _doc_delete <<<"$bad"
      [[ -z "$(nat_classify | awk -F'\t' '$1 == "bad"')" ]] && bad=""
    fi
  fi
  if [[ -n "$warn" ]]; then
    _doc_warn "${C_YELLOW}мёртвые перенаправления с 443 (там никто не слушает) — VPN не мешают, но это мусор:${C_RESET}"
    while IFS=$'\t' read -r kind loc dp to rule; do
      printf '      %s → %s   %s%s%s\n' "$dp" "$(_doc_target "$to")" "$C_DIM" "$rule" "$C_RESET"
    done <<<"$warn"
    if (( fixes )) && confirm "Удалить их?" y; then _doc_delete <<<"$warn"; fi
  fi
  if [[ -n "$info" ]]; then
    printf '  %sℹ%s перенаправления в порты Xray (похоже, настроены специально — не трогаю):\n' "$C_BLUE" "$C_RESET"
    while IFS=$'\t' read -r kind loc dp to rule; do
      printf '      %s → %s\n' "$dp" "$(_doc_target "$to")"
    done <<<"$info"
  fi

  printf '\n %s%sCron%s\n' "$C_BOLD" "$(ic ⏰)" "$C_RESET"
  if [[ -z "$jobs" ]]; then
    _doc_ok "заданий старого selfsteal нет"
  else
    _doc_bad "${C_RED}осталось продление старого selfsteal — оно снова поставит NAT на 443:${C_RESET}"
    printf '      %s\n' "$jobs"
    if (( fixes )) && confirm "Отключить эти задания (закомментировать)?" y; then _doc_fix_cron; fi
  fi
  if our_cron_ok; then _doc_ok "автопродление selfsteal-apps на месте"
  else _doc_warn "${C_YELLOW}задание продления selfsteal-apps пропало из cron${C_RESET} (его удаляет установщик DigneZzZ) — восстановить: selfsteal-apps cert renew"
  fi

  if is_installed; then
    _doc_sockets "$fixes" || true
    _doc_links
  fi

  printf '\n %s%sПорты%s\n' "$C_BOLD" "$(ic 🔌)" "$C_RESET"
  if [[ -n "$xp" ]]; then
    for p in $xp; do _doc_ok "TCP/$p — $(port_owner_tcp "$p" | tr -d '"')"; done
  else
    for p in $(site_ports); do
      owner="$(port_owner_tcp "$p" | tr -d '"')"
      if port_in_use_tcp "$p"; then _doc_ok "TCP/$p слушает ${owner:-процесс}"
      else _doc_warn "TCP/$p никто не слушает — Xray запущен? (на этом порту есть сайты)"; fi
    done
  fi

  [[ -z "$bad" ]]
}

# nginx log of the last 24h with docker timestamps (empty if unavailable).
_doc_nginx_log() { docker logs --timestamps --since 24h "$CONTAINER" 2>&1 || true; }

# "2026-11-18T23:19:59.123Z ..." -> "18.11 23:19"
_doc_when() { sed -E 's/^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}:[0-9]{2}).*/\3.\2 \4/' <<<"$1"; }

# Sockets between Xray and nginx: present on the host, listened on, visible inside the Xray container.
# Returns 1 if something is broken.
_doc_sockets() {
  [[ "$LISTEN_MODE" == "socket" ]] || return 0
  local fixes="${1:-0}" hp xp path reason c bad=0
  hp="$(socket_problems)"; xp="$(xray_socket_problems)"
  printf '\n %s%sСокеты Xray → nginx%s\n' "$C_BOLD" "$(ic 🔗)" "$C_RESET"
  if [[ -n "$hp" ]]; then
    bad=1
    while IFS=$'\t' read -r path reason; do
      case "$reason" in
        gone)    _doc_bad "${C_RED}$path удалён, хотя nginx его слушает${C_RESET} — подключиться к нему нельзя" ;;
        missing) _doc_bad "${C_RED}$path нет — nginx его не открыл${C_RESET}" ;;
      esac
    done <<<"$hp"
    if (( fixes )) && confirm "Пересоздать контейнер nginx (сокеты создадутся заново, займёт пару секунд)?" y; then
      restart_cmd && hp="$(socket_problems)" && [[ -z "$hp" ]] && { _doc_ok "сокеты на месте"; bad=0; xp="$(xray_socket_problems)"; }
    fi
  else
    _doc_ok "сокеты на месте: $(socket_paths | paste -sd' ' -)"
  fi
  if [[ -z "$(xray_containers)" ]]; then
    _doc_warn "контейнер Xray (remnanode) не найден — если Xray в Docker, ему нужен том /dev/shm:/dev/shm"
  elif [[ -z "$xp" ]]; then
    _doc_ok "Xray ($(xray_containers | paste -sd, -)) видит сокеты"
  else
    bad=1
    local need_shm=0 need_recreate=""
    while IFS=$'\t' read -r c path reason; do
      case "$reason" in
        no-shm)   _doc_bad "${C_RED}$c не монтирует /dev/shm${C_RESET} — видит свой пустой /dev/shm, сокеты ему недоступны"; need_shm=1 ;;
        not-seen) _doc_bad "${C_RED}$c не видит $path${C_RESET} — том /dev/shm добавлен, но контейнер не пересоздан"; need_recreate="$c" ;;
      esac
    done <<<"$xp"
    if (( fixes )); then
      if (( need_shm )); then check_xray_socket_access
      elif [[ -n "$need_recreate" ]] && confirm "Пересоздать $need_recreate? VPN на ноде прервётся на несколько секунд" n; then
        xray_recreate "$need_recreate"
      fi
      [[ -z "$(xray_socket_problems)" ]] && { _doc_ok "Xray видит сокеты"; bad=0; }
    fi
  fi
  return "$bad"
}

# Per public port: is there an Xray inbound, does it speak proxy protocol, does anything arrive.
_doc_links() {
  local log xp p names listen bh nbh last reqs nreq
  log="$(_doc_nginx_log)"
  xp=" $(xray_ports | tr '\n' ' ') "
  printf '\n %s%sСвязь Xray → nginx%s  %s(за сутки, по логам nginx)%s\n' "$C_BOLD" "$(ic 🧷)" "$C_RESET" "$C_DIM" "$C_RESET"
  for p in $(site_ports); do
    names="$(list_sites | awk -F@ -v p="$p" '$2 == p { n++; if (n <= 3) l = l (n > 1 ? ", " : "") $1 }
      END { if (n > 3) l = l " и ещё " (n - 3); print l }')"
    [[ -n "$names" ]] || continue
    listen="$(port_listen "$p")"
    if [[ "$xp" != "  " && "$xp" != *" $p "* ]]; then
      _doc_bad "${C_RED}порт $p: Xray его не слушает${C_RESET}, а на нём домены: $names — inbound на этом порту не создан или у него другой порт"
      continue
    fi
    if [[ "$PROXY_PROTOCOL" == "1" ]]; then
      bh="$(grep -F "while reading PROXY protocol" <<<"$log" | grep -F "server: $listen" || true)"
      nbh="$(grep -c . <<<"$bh" || true)"
      if (( nbh > 0 )); then
        last="$(_doc_when "$(tail -1 <<<"$bh")")"
        _doc_bad "${C_RED}порт $p: inbound присылает трафик без proxy protocol${C_RESET} ($nbh раз, последний $last) — в его realitySettings нужен \"xver\": 1"
        continue
      fi
    fi
    reqs="$(grep -E " port=${p}\$" <<<"$log" || true)"
    nreq="$(grep -c . <<<"$reqs" || true)"
    if (( nreq > 0 )); then
      _doc_ok "порт $p: запросов $nreq, последний $(_doc_when "$(tail -1 <<<"$reqs")") ($names)"
    else
      _doc_warn "порт $p: за сутки до nginx не дошло ни одного запроса ($names)."
      printf '      %sОткройте %s в браузере и запустите проверку снова. Открылось — всё в порядке, просто не было\n' "$C_DIM" "$(public_url "${names%%,*}" "$p")"
      printf '      посетителей. Не открылось и здесь пусто — проверьте inbound на порту %s: применён ли он к ноде\n' "$p"
      printf '      (профиль в Remnawave) и указан ли target %s, "xver": 1.%s\n' "$(port_target "$p")" "$C_RESET"
    fi
  done
}

doctor_cmd() {
  title "$(ic 🩺)Диагностика"
  local fix=0   # interactive: asks before each fix; non-interactive: only with --fix
  [[ "${1:-}" == "--fix" ]] && { fix=1; ASSUME_YES=1; }
  is_interactive && fix=1
  doctor_check "$fix" || { echo; warn "Перенаправления остались. Удалить: selfsteal-apps doctor (спросит подтверждение) или doctor --fix."; return 1; }
  echo
  log "Проверка завершена."
}

# Before install/adopt: stale NAT makes the new setup look broken. Ask, never remove silently.
doctor_preflight() {
  [[ -n "$(nat_classify | grep -E '^(bad|warn)')$(old_renew_jobs)" ]] || return 0
  warn "Найдены остатки другой selfsteal-установки, которые мешают Xray:"
  local fix=0; is_interactive && fix=1   # without a terminal: only report
  doctor_check "$fix" || warn "Перенаправления оставлены — пока они есть, эти inbound на ноде работать не будут."
  echo
}
