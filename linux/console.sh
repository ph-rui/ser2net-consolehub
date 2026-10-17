#!/usr/bin/env bash
# =============================================================================
#  console.sh - attach a Linux side to a USB-serial console port exported by a
#               Windows host running ser2net.
#
#  You refer to a DEVICE, never a COM number: the Windows side auto-remaps
#  COM numbers on every replug (the same adapter can be COM15 today and
#  COM42 tomorrow) and serves each device on a stable TCP port.
#
#  The device table is fetched from the Windows hub on every single run: the
#  hub's query-server answers "which ports do you have right now?", so a replug
#  is visible immediately.  There is deliberately NO local snapshot - if the hub
#  cannot be reached this script says so instead of quietly using a stale file.
#  Format per line:
#      alias  label  host  port
#
#  Usage:
#     ./console.sh                 # interactive on the default device (a)
#     ./console.sh a               # by alias
#     ./console.sh imx95-evk       # by label (case-insensitive, substring ok)
#     ./console.sh 4002            # by raw TCP port
#     ./console.sh --pty /dev/ttyUSB9 c     # expose a device node for an SDK
#     ./console.sh --list          # show the device table
#     ./console.sh --live --list   # same; kept for compatibility, the live query
#                                   # is now the only source, so it changes nothing
#     ./console.sh --ping          # is the hub there, and what does it have?
#
#  Interactive session: the terminal is put in raw mode by ptybridge.py (same
#  mechanism as `stty raw -echo`); keys go straight to the board (Ctrl+C
#  reaches the board, not this script).  Exit like picocom: press Ctrl+A
#  then x (or just Ctrl+]); the terminal is restored automatically.  To
#  send a literal Ctrl+A to the board, press Ctrl+A twice.  If the terminal
#  ever looks odd afterwards, run `reset` or `stty sane`.
#
#  `| tee` / script(1) capture is deliberately unsupported: capturing stdout
#  makes socat's raw mode abort ("Inappropriate ioctl for device"); the
#  python bridge also needs its stdin/stdout on one terminal.  Byte-level
#  session captures already live on the Windows host in logs/dev-<alias>.log
#  (ser2net trace-both); pull those when you need a record.
#
#  Where the device table comes from: the hub, every run.  Every execution asks
#  the Windows host "which ports do you have right now?"  No snapshot is kept
#  or consulted, so there is nothing to go stale and nothing to re-push; a hub
#  that cannot be reached is reported as an error.
#
#  Env overrides:
#     HUB_CONF        path to the "which hub" file (default /etc/ser2net-hub.conf,
#                     one line: QUERY_HOST=172.16.66.163).  Static config, not
#                     a render snapshot, so hub discovery survives the snapshot
#                     being missing or stale.
#     QUERY_HOST      hub to ask, overrides HUB_CONF
#     QUERY_PORT      live-query port (default 4099)
#     QUERY_TIMEOUT   seconds to wait for the answer (default 2)
#     HOST            default host if a target is given as a bare port
# =============================================================================
set -uo pipefail

HOST="${HOST:-172.16.66.163}"
# Live query: where the Windows hub answers "which serial ports do you have
# right now?".  This is the ONLY source of the device table.
QUERY_HOST="${QUERY_HOST:-}"
QUERY_PORT="${QUERY_PORT:-4099}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-2}"
# Static "which hub do I ask" file.  It answers the one question the live query
# cannot: WHICH hub to ask.  That has to be known before anything can be
# queried, so it cannot come from the hub itself.  A three-line hand-written
# file never goes stale, unlike a rendered snapshot.
HUB_CONF="${HUB_CONF:-/etc/ser2net-hub.conf}"
PTY=""
MODE="stdio"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }

command -v socat >/dev/null 2>&1 || die "socat not found. Install: apt install socat  /  yum install socat"

# ------------------------------------------------------------ device table
# The hub's answer, parsed into:
#   ENTRIES[]  = "alias|host|port|label"  (keeps display order)
#   ALIAS_PORT[alias], ALIAS_HOST[alias], ALIAS_LABEL[alias]  (lookup by alias)
declare -a ENTRIES=()
declare -A ALIAS_PORT=() ALIAS_HOST=() ALIAS_LABEL=()

SOURCE="none"

# Parse a table blob (the hub's live answer) into ENTRIES/ALIAS_*.
parse_table() {
  local text="$1" line f
  [[ -z "$text" ]] && return 1
  ENTRIES=()
  ALIAS_PORT=() ALIAS_HOST=() ALIAS_LABEL=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%"${line##*[![:space:]]}"}"     # rtrim
    [[ "$line" =~ ^# ]] && continue
    [[ -z "$line" ]] && continue
    read -ra f <<< "$line"
    [[ ${#f[@]} -lt 3 ]] && continue
    alias="${f[0]}"
    port="${f[-1]}"
    host="${f[-2]}"
    label="${f[*]:1:${#f[@]}-3}"
    ALIAS_PORT["$alias"]="$port"
    ALIAS_HOST["$alias"]="$host"
    ALIAS_LABEL["$alias"]="$label"
    ENTRIES+=("$alias|$host|$port|$label")
  done <<< "$text"
  return 0
}

# --------------------------------------------------------- live query
# Ask the hub for the CURRENT device table.  Returns table lines on stdout,
# empty output when the hub is unreachable.
#
# Deliberately a plain TCP round-trip, not a port probe: connect, read the
# reply, close.  This is NOT one of the ser2net console ports, so it cannot
# trigger the "Device open failure: Permission denied" quirk that a bare
# connect+close on ports 4000-4003 causes.
_query_hub_inner() {
  local host="$1" port="$2" req="${3:-devices}" qfd out
  exec {qfd}<>"/dev/tcp/$host/$port" || return 1
  printf '%s\n' "$req" >&"$qfd"
  # `timeout` bounds the read: a hub that accepts but never answers must not
  # hang the console.
  out=$(timeout "$QUERY_TIMEOUT" cat <&"$qfd" 2>/dev/null)
  exec {qfd}>&- 2>/dev/null
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Runs the query in a subshell with stderr muted, so bash's own
# "/dev/tcp/...: Connection refused" cannot leak onto the user's terminal while
# we silently fall back to the cached conf.
query_hub() {
  ( _query_hub_inner "$1" "$2" ) 2>/dev/null
}

# Is the hub answering?  One line, no table: who answered, what address it is
# reachable as, how many ports it has plugged in right now.  This separates the
# three failure modes a plain "connection refused" cannot tell apart:
#   hub process dead | network path broken | everything unplugged.
_hub_ping() {
  local host="$1" port="$2" qfd out
  exec {qfd}<>"/dev/tcp/$host/$port" || return 1
  printf 'ping\n' >&"$qfd"
  out=$(timeout "$QUERY_TIMEOUT" cat <&"$qfd" 2>/dev/null)
  exec {qfd}>&- 2>/dev/null
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Resolve the hub to ask: QUERY_HOST, else HUB_CONF, else the hub named in the
# cached conf.  HUB_CONF is checked BEFORE the snapshot on purpose: the snapshot
# is the thing most likely to be missing or stale, and if we learned the hub
# address only from it, losing it would silently downgrade the client to the
# legacy slot path - which aims at $HOST, potentially a different machine.
resolve_query_target() {
  if [[ -n "$QUERY_HOST" ]]; then printf '%s' "$QUERY_HOST"; return 0; fi
  if [[ -r "$HUB_CONF" ]]; then
    local v
    v="$(sed -n 's/^[[:space:]]*QUERY_HOST[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$HUB_CONF" 2>/dev/null | head -1)"
    if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
  fi
  return 1
}

# ------------------------------------------------------------------ args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pty)  PTY="$2"; MODE="pty"; shift 2 ;;
    --nolog) shift ;;  # no-op, kept for back-compat; local logging was removed
                       # because tee/script capture breaks socat raw mode
    --list) MODE="list"; shift ;;
    --live) shift ;;   # no-op: the live query is now the only source
    --ping)  MODE="ping"; shift ;;   # hub liveness / live inventory, one line
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)  TARGET="$1"; shift ;;
  esac
done

# --------------------------------------------------------- resolve the table
# The hub is the only source.  An unreachable hub is a hard error: there is no
# snapshot to fall back on any more, and inventing one would be worse than
# failing, because the result would be a connection to the wrong thing.
qh="$(resolve_query_target)" \
  || die "no hub to query. Set QUERY_HOST, or write QUERY_HOST=<ip> into $HUB_CONF"
if live="$(query_hub "$qh" "$QUERY_PORT")" && [[ -n "$live" ]]; then
  parse_table "$live" || die "hub $qh:$QUERY_PORT returned no usable devices"
  SOURCE="live ($qh:$QUERY_PORT)"
else
  die "hub $qh:$QUERY_PORT did not answer. The hub runs ser2net + query-server; check it is up (try: console.sh --ping)"
fi

# ------------------------------------------------------------------- ping
if [[ "${MODE}" == "ping" ]]; then
  qh="$(resolve_query_target)" || die "no hub to query (set QUERY_HOST or write $HUB_CONF)"
  out="$(_hub_ping "$qh" "$QUERY_PORT")" || die "hub $qh:$QUERY_PORT did not answer (query-server down?)"
  [[ -n "$out" ]] || die "hub $qh:$QUERY_PORT connected but sent nothing"
  printf '%s\n' "$out"
  exit 0
fi

# ------------------------------------------------------------------- list
if [[ "${MODE}" == "list" ]]; then
  # Reaching here means the hub answered, so there is always a table.  A hub
  # with nothing plugged in legitimately reports zero rows.
  printf '%-6s %-28s %s\n' 'alias' 'label' 'endpoint'
  for e in "${ENTRIES[@]}"; do
    IFS='|' read -r a h p l <<< "$e"
    printf '%-6s %-28s %s:%s\n' "$a" "$l" "$h" "$p"
  done
  printf '\n(source: %s)\n' "$SOURCE"
  [[ ${#ENTRIES[@]} -eq 0 ]] && printf 'no device plugged in right now\n'
  exit 0
fi

# -------------------------------------------------------------- resolve
TARGET="${TARGET:-a}"

if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  # raw port
  PORT="$TARGET"
  SLOT="port-$TARGET"
  LABEL=""
else
  key="$(echo "$TARGET" | tr 'A-Z' 'a-z')"
  if [[ -n "${ALIAS_PORT[$key]+x}" ]]; then
    PORT="${ALIAS_PORT[$key]}"
    HOST="${ALIAS_HOST[$key]}"
    LABEL="${ALIAS_LABEL[$key]}"
    SLOT="$key"
  else
    # label match: case-insensitive, substring ok
    found=""
    for e in "${ENTRIES[@]}"; do
      IFS='|' read -r a h p l <<< "$e"
      if grep -qi "$(echo "$TARGET" | sed 's/[.[\*^$()+?{|]/\\&/g')" <<< "$l"; then
        found="$a|$h|$p|$l"; break
      fi
    done
    if [[ -n "$found" ]]; then
      IFS='|' read -r SLOT HOST PORT LABEL <<< "$found"
    else
      die "unknown device '$TARGET'. Use an alias, a label, a port number, or --list"
    fi
  fi
fi

# ------------------------------------------------------------------ run
# Deliberately NO TCP preflight / reachability probe here: a bare TCP
# connect + immediate close (the old `/dev/tcp` check, or `nc -z`) makes
# the NEXT connection on that port fail on the Windows side with
# "Device open failure: Permission denied" (ser2net/gensio + WCH driver
# quirk).  ptybridge.py is the connectivity probe now: it prints a clear
# error if the host is unreachable, and auto-reconnects once if ser2net
# answers with a transient device-open failure.

info "device ${SLOT}${LABEL:+/ $LABEL} -> $HOST:$PORT"

# ------------------------------------------------------------------ run
if [[ "$MODE" == "pty" ]]; then
  info "exposing $HOST:$PORT (device $SLOT) as $PTY"
  info "point your program at $PTY"
  rm -f "$PTY"
  exec socat -d -d \
      "PTY,link=$PTY,raw,echo=0,mode=0666,waitslave" \
      "TCP:$HOST:$PORT,connect-timeout=5,nodelay"
fi

TCP_TARGET="TCP:$HOST:$PORT,connect-timeout=5,nodelay"

# Not a real terminal at all (e.g. ssh -T, some web consoles): raw termios
# cannot apply.  Fall back to plain passthrough - Ctrl+C then hits this
# host's shell, not the board.
if [[ ! -t 0 || ! -t 1 ]]; then
  info "stdin/stdout is not a terminal - running plain passthrough (no raw/echo)"
  exec socat - "$TCP_TARGET"
fi

# Real terminal: pass through via the python console bridge (ptybridge.py).
# It puts the terminal raw with termios - the same reliable mechanism as
# `stty raw -echo` - so every byte is forwarded untouched (Ctrl+C reaches the
# board) and it exits like picocom (Ctrl+A then x, or Ctrl+]) and restores the
# terminal.  socat's own `-,raw,echo=0` is NOT used: it tcsetattr's a dup of
# stdout and dies with "Inappropriate ioctl for device" as soon as stdout is
# captured by anything.
if command -v python3 >/dev/null 2>&1; then
  exec python3 "$(dirname "$0")/ptybridge.py" "$HOST" "$PORT"
fi

info "python3 not found - plain passthrough (Ctrl+C exits this console, NOT the board)"
exec socat - "$TCP_TARGET"