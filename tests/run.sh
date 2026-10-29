#!/bin/sh
# boink test suite (POSIX). Runs the state machine, the hook notifier, the
# daemon fallback, hermetic scheduler generation, and — on the right OS — the
# REAL scheduler (cron on Linux, launchd on macOS) to prove a BOINK actually
# fires and is delivered.
#
#   sh tests/run.sh
set -u

BOINK="$(cd "$(dirname "$0")/.." && pwd -P)/boink"
TMP="$(mktemp -d)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
contains() { # contains <desc> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 ('$3' missing '$2')" ;; esac
}
new_state() { # new_state <name>
  d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"
}

install_hook() { # install_hook <state-dir> <sentinel-file>
  mkdir -p "$1/hooks"
  cat > "$1/hooks/on-boink" <<EOF
#!/bin/sh
echo "\$BOINK_SEQ" >> "$2"
EOF
  chmod +x "$1/hooks/on-boink"
}

# ---------------------------------------------------------------------------
# 1. core state machine (no scheduler)
# ---------------------------------------------------------------------------
S1="$(new_state s1)"
BOINK_DIR="$S1" BOINK_SCHEDULER=none sh "$BOINK" arm --tag build-1 >/dev/null
check "arm registers a monitor" "1" "$(grep -c . "$S1/monitors")"
BOINK_DIR="$S1" BOINK_SCHEDULER=none sh "$BOINK" arm --tag build-1 >/dev/null
check "arm is idempotent" "1" "$(grep -c . "$S1/monitors")"

BOINK_DIR="$S1" BOINK_SCHEDULER=none sh "$BOINK" tick 2>/dev/null
BOINK_DIR="$S1" BOINK_SCHEDULER=none sh "$BOINK" tick 2>/dev/null
contains "tick appends a BOINK event" "BOINK seq=2" "$(cat "$S1/boink.log")"
check "seq advances" "2" "$(cat "$S1/seq")"
contains "last file updated" "monitors=1" "$(cat "$S1/last")"

BOINK_DIR="$S1" BOINK_SCHEDULER=none sh "$BOINK" disarm build-1 >/dev/null
check "disarm removes the monitor" "0" "$(grep -c . "$S1/monitors")"
seq_before="$(cat "$S1/seq")"
BOINK_DIR="$S1" BOINK_SCHEDULER=none sh "$BOINK" tick 2>/dev/null
check "tick is silent at zero monitors" "$seq_before" "$(cat "$S1/seq")"

# ---------------------------------------------------------------------------
# 2. hook notifier (no scheduler)
# ---------------------------------------------------------------------------
S2="$(new_state s2)"; SENT2="$TMP/sent2"
install_hook "$S2" "$SENT2"
BOINK_DIR="$S2" BOINK_SCHEDULER=none sh "$BOINK" arm --tag hook-test >/dev/null
BOINK_DIR="$S2" BOINK_SCHEDULER=none sh "$BOINK" tick 2>/dev/null
if [ -s "$SENT2" ]; then ok "hook fired on tick"; else bad "hook fired on tick (sentinel empty)"; fi
contains "hook received seq=1" "1" "$(cat "$SENT2" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 3. daemon fallback notifier (fast, real loop)
# ---------------------------------------------------------------------------
S3="$(new_state s3)"; SENT3="$TMP/sent3"
install_hook "$S3" "$SENT3"
BOINK_DIR="$S3" BOINK_SCHEDULER=none sh "$BOINK" arm --tag daemon-test --interval 1 >/dev/null
BOINK_DIR="$S3" BOINK_SCHEDULER=none sh "$BOINK" daemon >/dev/null 2>&1 &
DPID=$!
sleep 4
kill "$DPID" 2>/dev/null || true
wait "$DPID" 2>/dev/null || true
n="$(grep -c '^BOINK ' "$S3/boink.log" 2>/dev/null || true)"
if [ "$n" -ge 2 ]; then ok "daemon emitted >=2 BOINKs (got $n)"; else bad "daemon emitted >=2 BOINKs (got $n)"; fi
if [ -s "$SENT3" ]; then ok "daemon hook fired"; else bad "daemon hook fired (sentinel empty)"; fi

# ---------------------------------------------------------------------------
# 4. hermetic cron generation (stub crontab; any OS)
# ---------------------------------------------------------------------------
S4="$(new_state s4)"; FAKECRON="$TMP/fakecrontab"; mkdir -p "$TMP/bin4"
cat > "$TMP/bin4/crontab" <<EOF
#!/bin/sh
case "\${1:-}" in
  -l) [ -f "$FAKECRON" ] && cat "$FAKECRON" || true; exit 0 ;;
  *) cat > "$FAKECRON"; exit 0 ;;
esac
EOF
chmod +x "$TMP/bin4/crontab"
PATH="$TMP/bin4:$PATH" BOINK_BACKEND=cron BOINK_DIR="$S4" sh "$BOINK" arm --tag cron-gen --interval 60 >/dev/null
contains "cron block has begin marker" "boink:begin" "$(cat "$FAKECRON" 2>/dev/null)"
contains "cron block has minute spec" "* * * * *" "$(cat "$FAKECRON" 2>/dev/null)"
contains "cron block passes --dir" "$S4" "$(cat "$FAKECRON" 2>/dev/null)"
contains "cron block calls tick" "tick" "$(cat "$FAKECRON" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 5. hermetic launchd generation (stub launchctl; any OS)
# ---------------------------------------------------------------------------
S5="$(new_state s5)"; HOME5="$TMP/home5"; mkdir -p "$HOME5" "$TMP/bin5"
cat > "$TMP/bin5/launchctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin5/launchctl"
HOME="$HOME5" PATH="$TMP/bin5:$PATH" BOINK_BACKEND=launchd BOINK_DIR="$S5" sh "$BOINK" arm --tag launch-gen --interval 10 >/dev/null
PLIST="$HOME5/Library/LaunchAgents/com.fcecin.boink.plist"
if [ -f "$PLIST" ]; then
  ok "launchd plist written"
  contains "launchd plist StartInterval" "<integer>10</integer>" "$(cat "$PLIST")"
  contains "launchd plist calls tick" "tick" "$(cat "$PLIST")"
  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$PLIST" >/dev/null 2>&1; then ok "launchd plist passes plutil -lint"; else bad "launchd plist passes plutil -lint"; fi
  fi
else
  bad "launchd plist written"
fi

# ---------------------------------------------------------------------------
# 6. REAL cron fires a BOINK (Linux only)
# ---------------------------------------------------------------------------
cron_running() { pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; }

if [ "$(uname -s)" = "Linux" ] && command -v crontab >/dev/null 2>&1 && cron_running; then
  S6="$(new_state s6)"; SENT6="$TMP/sent6"
  install_hook "$S6" "$SENT6"
  cleanup6() { sh "$BOINK" --dir "$S6" off >/dev/null 2>&1 || true; }
  trap cleanup6 EXIT
  BOINK_DIR="$S6" sh "$BOINK" arm --tag cron-fire --interval 60 >/dev/null
  now="$(date +%s)"; next_min=$(( (now / 60 + 1) * 60 )); wait=$(( next_min - now + 20 ))
  printf 'ok   waiting %ss for real cron to fire...\n' "$wait"
  sleep "$wait"
  n6="$(grep -c '^BOINK ' "$S6/boink.log" 2>/dev/null || true)"
  if [ "$n6" -ge 1 ]; then ok "real cron fired a BOINK (got $n6)"; else bad "real cron fired a BOINK (got $n6)"; fi
  if [ -s "$SENT6" ]; then ok "real cron hook delivered (seq $(cat "$SENT6" | tr '\n' ','))"; else bad "real cron hook delivered (sentinel empty)"; fi
  sh "$BOINK" --dir "$S6" off >/dev/null 2>&1 || true
  trap - EXIT
else
  printf 'skip real cron test (%s, crontab=%s, cron-daemon=%s)\n' \
    "$(uname -s)" "$(command -v crontab >/dev/null 2>&1 && echo yes || echo no)" \
    "$(cron_running && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# 7. REAL launchd fires a BOINK (macOS only)
# ---------------------------------------------------------------------------
if [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
  S7="$(new_state s7)"; SENT7="$TMP/sent7"
  install_hook "$S7" "$SENT7"
  cleanup7() { sh "$BOINK" --dir "$S7" off >/dev/null 2>&1 || true; }
  trap cleanup7 EXIT
  BOINK_DIR="$S7" sh "$BOINK" arm --tag launchd-fire --interval 10 >/dev/null
  printf 'ok   waiting 30s for real launchd to fire...\n'
  sleep 30
  n7="$(grep -c '^BOINK ' "$S7/boink.log" 2>/dev/null || true)"
  if [ "$n7" -ge 1 ]; then ok "real launchd fired a BOINK (got $n7)"; else bad "real launchd fired a BOINK (got $n7)"; fi
  if [ -s "$SENT7" ]; then ok "real launchd hook delivered"; else bad "real launchd hook delivered (sentinel empty)"; fi
  sh "$BOINK" --dir "$S7" off >/dev/null 2>&1 || true
  trap - EXIT
else
  printf 'skip real launchd test (uname=%s)\n' "$(uname -s)"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
