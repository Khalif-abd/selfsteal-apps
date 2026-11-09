# shellcheck shell=bash
# Certificates via acme.sh (http-01 webroot through our nginx on :80).
# acme.sh lives in its own home ($ACME_HOME) so it never collides with an
# existing ~/.acme.sh (e.g. one installed by another selfsteal script).

ACME_BIN="$ACME_HOME/acme.sh"
ACME_SERVER="${ACME_SERVER:-letsencrypt}"

acme() { "$ACME_BIN" --home "$ACME_HOME" --config-home "$ACME_HOME/data" "$@"; }

acme_installed() { [[ -x "$ACME_BIN" ]]; }

ensure_cron() {
  have crontab && return 0
  info "Устанавливаю cron (нужен для автопродления сертификатов)..."
  pkg_install cron || pkg_install cronie || true
  have systemctl && { systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true; }
  have crontab || die "cron не установлен — поставьте его вручную и повторите."
}

ensure_acme() {
  acme_installed && return 0
  ensure_cron
  have git || pkg_install git || die "git обязателен для установки acme.sh."
  info "Устанавливаю acme.sh в $ACME_HOME ..."
  local tmp; tmp="$(mktemp -d)"
  git clone -q --depth 1 https://github.com/acmesh-official/acme.sh.git "$tmp/acme.sh" ||
    { rm -rf "$tmp"; die "Не удалось скачать acme.sh."; }
  local args=(--install --home "$ACME_HOME" --config-home "$ACME_HOME/data")
  [[ -n "$ACME_EMAIL" ]] && args+=(--accountemail "$ACME_EMAIL")
  ( cd "$tmp/acme.sh" && ./acme.sh "${args[@]}" >/dev/null ) ||
    { rm -rf "$tmp"; die "Установка acme.sh не удалась."; }
  rm -rf "$tmp"
  acme --set-default-ca --server "$ACME_SERVER" >/dev/null
  acme --upgrade --auto-upgrade 0 >/dev/null 2>&1 || true
  log "acme.sh установлен, автопродление — через cron (ежедневно)."
}

# Quick local self-check that nginx serves the challenge path for this host.
_acme_selfcheck() {
  local d="$1" token body
  token="ssa-check-$RANDOM$RANDOM"
  printf '%s' "$token" > "$ACME_WEBROOT/.well-known/acme-challenge/$token"
  chmod 644 "$ACME_WEBROOT/.well-known/acme-challenge/$token"
  body="$(curl -fsS --max-time 5 --resolve "$d:80:127.0.0.1" "http://$d/.well-known/acme-challenge/$token" 2>/dev/null || true)"
  rm -f "$ACME_WEBROOT/.well-known/acme-challenge/$token"
  [[ "$body" == "$token" ]]
}

check_dns() {
  local d="$1" ips
  [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(detect_public_ip || true)"
  ips="$(resolve_a "$d")"
  if [[ -z "$ips" ]]; then
    warn "$d не резолвится (нет A-записи)."
    return 1
  fi
  if [[ -n "$PUBLIC_IP" ]] && ! grep -qx "$PUBLIC_IP" <<<"$ips"; then
    warn "$d указывает на $(tr '\n' ' ' <<<"$ips")— а IP сервера $PUBLIC_IP."
    return 1
  fi
  log "DNS: $d -> $PUBLIC_IP"
}

# Copies the issued cert into nginx's ssl dir; acme.sh repeats this on renewal.
_acme_install_cert() {
  local d="$1"
  install -d -m 700 "$NGINX_SSL/$d"
  acme --install-cert -d "$d" --ecc \
    --fullchain-file "$(cert_path "$d")" \
    --key-file "$(cert_key_path "$d")" \
    --reloadcmd "docker exec $CONTAINER nginx -s reload >/dev/null 2>&1" >/dev/null
}

# issue_cert DOMAIN [force]
issue_cert() {
  local d="$1" force="${2:-}" rc=0 out
  ensure_acme
  container_running || die "nginx не запущен — сначала 'selfsteal-apps install'."

  if [[ "${SSA_SKIP_DNS_CHECK:-0}" != "1" ]] && ! check_dns "$d"; then
    # never auto-confirm this one: a pointless attempt just burns Let's Encrypt rate limits
    if ! is_interactive || ! confirm "DNS не совпадает. Всё равно пытаться выпустить сертификат?" n; then
      return 1
    fi
  fi
  if ! _acme_selfcheck "$d"; then
    err "nginx не отдаёт /.well-known/acme-challenge/ для $d на :80 локально."
    return 1
  fi

  info "Выпускаю сертификат для $d (Let's Encrypt, http-01)..."
  local args=(--issue -d "$d" -w "$ACME_WEBROOT" --server "$ACME_SERVER" --keylength ec-256)
  [[ "$force" == "force" ]] && args+=(--force)
  out="$(acme "${args[@]}" 2>&1)" || rc=$?
  # rc 2 = cert still valid, nothing to do
  if (( rc != 0 && rc != 2 )); then
    err "acme.sh не смог выпустить сертификат для $d:"
    printf '%s\n' "$out" | tail -n 15 >&2
    warn "Проверьте: A-запись домена, открыт ли TCP/80 снаружи (ufw/security group)."
    return 1
  fi
  _acme_install_cert "$d" || { err "Не удалось установить сертификат в $NGINX_SSL/$d."; return 1; }
  log "Сертификат для $d готов."
}

# Use an existing cert/key (e.g. wildcard). Not auto-renewed.
install_manual_cert() {
  local d="$1" crt="$2" key="$3"
  [[ -s "$crt" && -s "$key" ]] || die "Файлы сертификата/ключа не найдены."
  openssl x509 -in "$crt" -noout >/dev/null 2>&1 || die "$crt — не похоже на сертификат."
  install -d -m 700 "$NGINX_SSL/$d"
  install -m 644 "$crt" "$(cert_path "$d")"
  install -m 600 "$key" "$(cert_key_path "$d")"
  log "Сертификат для $d установлен из файлов (автопродления нет)."
}

remove_cert() {
  local d="$1"
  if acme_installed; then
    acme --remove -d "$d" --ecc >/dev/null 2>&1 || true
    rm -rf "${ACME_HOME:?}/data/${d}_ecc" "${ACME_HOME:?}/certs/${d}_ecc"
  fi
  rm -rf "${NGINX_SSL:?}/$d"
}

renew_all() {
  ensure_acme
  info "Продлеваю сертификаты, срок которых подходит..."
  acme --cron || warn "acme.sh --cron завершился с ошибкой."
}

# cert_info DOMAIN -> "expires YYYY-MM-DD (N days) issuer"
cert_days_left() {
  local f; f="$(cert_path "$1")"
  [[ -s "$f" ]] || return 1
  local end end_s now_s
  end="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)" || return 1
  end_s="$(date -d "$end" +%s 2>/dev/null)" || return 1
  now_s="$(date +%s)"
  echo $(( (end_s - now_s) / 86400 ))
}

cert_summary() {
  local d="$1" f days end issuer
  f="$(cert_path "$d")"
  if [[ ! -s "$f" ]]; then printf '%sнет сертификата%s' "$C_RED" "$C_RESET"; return; fi
  end="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)"
  issuer="$(openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed -n 's/.*O *= *\([^,]*\).*/\1/p')"
  [[ -n "$issuer" ]] || issuer="$(openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')"
  [[ "$(openssl x509 -in "$f" -noout -subject 2>/dev/null)" == "$(openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed 's/^issuer/subject/')" ]] && issuer="self-signed"
  days="$(cert_days_left "$d" || echo '?')"
  local color="$C_GREEN"
  [[ "$days" =~ ^-?[0-9]+$ ]] && { (( days < 14 )) && color="$C_YELLOW"; (( days < 0 )) && color="$C_RED"; }
  printf '%s%s дн.%s (до %s, %s)' "$color" "$days" "$C_RESET" "$(date -d "$end" +%F 2>/dev/null || echo "$end")" "${issuer:-?}"
}
