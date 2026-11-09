#!/usr/bin/env bash
# Installs/updates the selfsteal-apps CLI:
#   code -> /usr/local/lib/selfsteal-apps, command -> /usr/local/bin/selfsteal-apps
#
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/Khalif-abd/selfsteal-apps/main/install.sh)
set -Eeuo pipefail

REPO="${SSA_REPO:-Khalif-abd/selfsteal-apps}"
BRANCH="${SSA_BRANCH:-main}"
LIB_DIR="${SSA_LIB_DIR:-/usr/local/lib/selfsteal-apps}"
BIN_LINK="${SSA_BIN_LINK:-/usr/local/bin/selfsteal-apps}"
TARBALL="${SSA_TARBALL:-https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz}"

say() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите от root (sudo)."
command -v curl >/dev/null || die "Нужен curl."
command -v tar  >/dev/null || die "Нужен tar."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "Скачиваю ${REPO}@${BRANCH}..."
curl -fsSL "$TARBALL" -o "$tmp/src.tgz" || die "Не удалось скачать $TARBALL"
tar -xzf "$tmp/src.tgz" -C "$tmp"
src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -f "$src/selfsteal-apps" && -d "$src/lib" ]] || die "Архив не похож на selfsteal-apps."

for f in "$src/selfsteal-apps" "$src"/lib/*.sh; do
  bash -n "$f" || die "Синтаксическая ошибка в $(basename "$f") — установка отменена."
done

# Atomic swap of the code directory
new="${LIB_DIR}.new.$$"
rm -rf "$new"
install -d -m 755 "$new"
cp -a "$src/selfsteal-apps" "$src/lib" "$new/"
[[ -d "$src/apps" ]] && cp -a "$src/apps" "$new/"
[[ -f "$src/VERSION" ]] && cp -a "$src/VERSION" "$new/"
chmod 755 "$new/selfsteal-apps"
if [[ -d "$LIB_DIR" ]]; then
  old="${LIB_DIR}.old.$$"
  mv "$LIB_DIR" "$old" && mv "$new" "$LIB_DIR" && rm -rf "$old"
else
  mv "$new" "$LIB_DIR"
fi
ln -sfn "$LIB_DIR/selfsteal-apps" "$BIN_LINK"

say "Установлено: $BIN_LINK ($(cat "$LIB_DIR/VERSION" 2>/dev/null || echo dev))"

if [[ "${SSA_NO_LAUNCH:-0}" != "1" ]]; then
  say "Запуск меню: sudo selfsteal-apps"
  if [[ -t 0 ]]; then
    exec "$BIN_LINK"
  elif { : </dev/tty; } 2>/dev/null; then
    exec "$BIN_LINK" </dev/tty
  fi
fi
