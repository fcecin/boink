#!/bin/sh
# boink installer (Linux / macOS / Unix, incl. Git Bash on Windows).
#   install.sh [install|status|uninstall] [--prefix DIR]
# Idempotent. Symlinks `boink` into a directory on your PATH and drops a
# non-executable example hook into ~/.boink/hooks/.
set -eu

REPO="$(cd "$(dirname "$0")" && pwd -P)"
PREFIX="${BOINK_PREFIX:-$HOME/.local/bin}"
CMD=install

for a in "$@"; do case "$a" in
  install|status|uninstall) CMD="$a" ;;
  --prefix) PREFIX="$2"; shift 2 ;;
  --prefix=*) PREFIX="${a#--prefix=}" ;;
  -h|--help) sed -n '2p' "$0" | sed 's/^# //'; exit 0 ;;
  *) echo "unknown argument: $a" >&2; exit 2 ;;
esac; done

say() { printf '%-8s %s\n' "$1" "$2"; }
LINK="$PREFIX/boink"

linked() { [ -L "$LINK" ] && [ "$(readlink -f "$LINK" 2>/dev/null || readlink "$LINK")" = "$REPO/boink" ]; }

on_path() {
  case ":$PATH:" in
    *":$PREFIX:"*) return 0 ;;
    *) return 1 ;;
  esac
}

case "$CMD" in
  install)
    if linked; then
      say ok "already linked: $LINK"
    else
      mkdir -p "$PREFIX"
      chmod +x "$REPO/boink" 2>/dev/null || true
      ln -sf "$REPO/boink" "$LINK"
      say linked "$LINK -> $REPO/boink"
    fi
    mkdir -p "$HOME/.boink/hooks"
    if [ -f "$REPO/hooks/on-boink.example" ]; then
      cp -n "$REPO/hooks/on-boink.example" "$HOME/.boink/hooks/on-boink.example" 2>/dev/null || true
      say hook "example hook at $HOME/.boink/hooks/on-boink.example (rename to enable)"
    fi
    if on_path; then
      say path "$PREFIX is on PATH"
    else
      say path "add $PREFIX to your PATH (e.g. export PATH=\"$PREFIX:\$PATH\")"
    fi
    say done "arm a monitor with: boink arm --tag <name>"
    ;;
  status)
    say repo "$REPO"
    if linked; then say skill "boink installed at $LINK"; else say skill "not installed"; fi
    if on_path; then say path "$PREFIX on PATH"; else say path "$PREFIX NOT on PATH"; fi
    ;;
  uninstall)
    if [ -L "$LINK" ]; then rm -f "$LINK"; say removed "$LINK"; else say ok "nothing at $LINK"; fi
    ;;
esac
