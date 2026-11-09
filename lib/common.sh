# shellcheck shell=bash
# Common helpers: logging, prompts, validation, small utilities.

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

LOG_FILE="${LOG_FILE:-/var/log/selfsteal-apps.log}"

_log_file() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

log()  { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _log_file "[+] $*"; }
info() { printf '%s[i]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; _log_file "[i] $*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log_file "[!] $*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log_file "[x] $*"; }
die()  { err "$*"; exit 1; }

hr()     { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────" "$C_RESET"; }
title()  { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; hr; }

have() { command -v "$1" >/dev/null 2>&1; }

# ASSUME_YES=1 makes confirm() answer with its default "yes" path and ask() use defaults.
ASSUME_YES="${ASSUME_YES:-0}"

is_interactive() { [[ "$ASSUME_YES" != "1" && -t 0 ]]; }

# confirm "Question" [default y|n]
confirm() {
  local q="$1" def="${2:-n}" ans hint
  [[ "$def" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  if ! is_interactive; then
    [[ "$ASSUME_YES" == "1" || "$def" == "y" ]]
    return
  fi
  read -r -p "$(printf '%s?%s %s %s ' "$C_CYAN" "$C_RESET" "$q" "$hint")" ans || ans=""
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[YyДд] ]]
}

# ask VAR "Question" [default]
ask() {
  local __var="$1" q="$2" def="${3:-}" ans
  if ! is_interactive; then
    printf -v "$__var" '%s' "$def"
    return
  fi
  if [[ -n "$def" ]]; then
    read -r -p "$(printf '%s?%s %s %s[%s]%s: ' "$C_CYAN" "$C_RESET" "$q" "$C_DIM" "$def" "$C_RESET")" ans || ans=""
  else
    read -r -p "$(printf '%s?%s %s: ' "$C_CYAN" "$C_RESET" "$q")" ans || ans=""
  fi
  printf -v "$__var" '%s' "${ans:-$def}"
}

# choose VAR "Question" default_index "opt1" "opt2" ...   (stores the chosen option text)
choose() {
  local __var="$1" q="$2" def="$3"; shift 3
  local opts=("$@") i ans
  if ! is_interactive; then
    printf -v "$__var" '%s' "${opts[$((def-1))]}"
    return
  fi
  printf '%s?%s %s\n' "$C_CYAN" "$C_RESET" "$q"
  for i in "${!opts[@]}"; do
    printf '   %s%d)%s %s\n' "$C_BOLD" "$((i+1))" "$C_RESET" "${opts[$i]}"
  done
  while :; do
    read -r -p "   Выбор [${def}]: " ans || ans=""
    ans="${ans:-$def}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
      printf -v "$__var" '%s' "${opts[$((ans-1))]}"
      return
    fi
    warn "Введите число от 1 до ${#opts[@]}."
  done
}

pause() { is_interactive && read -r -p "$(printf '%sEnter — продолжить...%s' "$C_DIM" "$C_RESET")" _ || true; }

valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_ipv4()   { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
# Strict FQDN check: also protects generated configs/filenames from injection.
valid_domain() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] && (( ${#1} <= 253 ))
}
valid_email()  { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

detect_public_ip() {
  local u ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    if valid_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

# IPv4 addresses a domain resolves to (one per line).
resolve_a() {
  local d="$1"
  if have dig; then
    dig +short A "$d" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true
  elif have getent; then
    getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u || true
  fi
}

pkg_install() {
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
  elif have dnf; then dnf install -y -q "$@" >/dev/null 2>&1
  elif have yum; then yum install -y -q "$@" >/dev/null 2>&1
  elif have apk; then apk add --quiet "$@" >/dev/null 2>&1
  else return 1
  fi
}

port_in_use_tcp() { ss -Htln "sport = :$1" 2>/dev/null | grep -q .; }
port_owner_tcp()  { ss -Htlnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:((\("[^"]*"\).*/\1/p' | head -1; }

ts() { date +%Y%m%d-%H%M%S; }
