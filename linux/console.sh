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
#     HUB_CONF        path to the "which hub" file (default /etc/ser2net-hub.conf).
#                     Recognised keys, one per line:
#                         QUERY_HOST=<ip>            (or <ip>:<port>)
#                         QUERY_PORT=<port>
#                     Hand-written static config, not a render snapshot.
#     QUERY_HOST      hub to ask, overrides HUB_CONF; <ip>:<port> also works
#     QUERY_PORT      live-query port (default 4099); wins over HUB_CONF
#     QUERY_TIMEOUT   seconds to wait for the answer (default 4)
#     HOST            default host if a target is given as a bare port
# =============================================================================
set -uo pipefail

HOST="${HOST:-192.168.1.10}"
# Live query: where the Windows hub answers "which serial ports do you have
# right now?".  This is the ONLY source of the device table.
#
# Remember whether the port came from the environment: only then does it
# override a QUERY_PORT line in HUB_CONF (see resolve_query_target).
QUERY_PORT_FROM_ENV=0
if [[ -n "${QUERY_PORT:-}" ]]; then QUERY_PORT_FROM_ENV=1; fi
QUERY_HOST="${QUERY_HOST:-}"
QUERY_PORT="${QUERY_PORT:-4099}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-4}"
# Static "which hub do I ask" file.  It answers the one question the live query
# cannot: WHICH hub to ask.  That has to be known before anything can be
# queried, so it cannot come from the hub itself.  A three-line hand-written
# file never goes stale, unlike a rendered snapshot.
HUB_CONF="${HUB_CONF:-/etc/ser2net-hub.conf}"
PTY=""
MODE="stdio"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }

# socat is only needed to CONNECT (pty mode / non-tty passthrough).  --list and
# --ping are pure TCP and must keep working on a box that never installed it.
need_socat() {
  command -v socat >/dev/null 2>&1 || die "socat not found. Install: apt install socat  /  yum install socat"
}

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
# One retry: the hub is a single-threaded PowerShell loop, so a stray zero-byte
# connection (a port probe, a health check) makes the FIRST real query wait for
# its read timeout before the server gets to us.  That looks like "hub did not
# answer" even though the very next run succeeds.  The retry turns it into a
# short pause instead of an error; a genuinely dead hub still fails fast.
query_hub() {
  local i out
  for i in 1 2; do
    out="$( ( _query_hub_inner "$1" "$2" ) 2>/dev/null )"
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out"
      return 0
    fi
    [[ $i -eq 1 ]] && sleep 0.3
  done
  return 1
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

# Same one-retry rule as query_hub (see the comment there).
ping_hub() {
  local i out
  for i in 1 2; do
    out="$(_hub_ping "$1" "$2" 2>/dev/null)"
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out"
      return 0
    fi
    [[ $i -eq 1 ]] && sleep 0.3
  done
  return 1
}

# Read one KEY=VALUE line from HUB_CONF (comment lines and stray whitespace are
# tolerated).  Returns empty when the file or key is missing.
conf_value() {
  [[ -r "$HUB_CONF" ]] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$HUB_CONF" 2>/dev/null \
    | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}

# Print "host port" for the hub to ask.  Accepts a bare address or addr:port in
# both QUERY_HOST and HUB_CONF; a QUERY_PORT line in HUB_CONF is honoured unless
# the environment set QUERY_PORT explicitly.
resolve_query_target() {
  local v="" p="" hport="$QUERY_PORT"
  if [[ -n "$QUERY_HOST" ]]; then
    v="$QUERY_HOST"
  elif [[ -r "$HUB_CONF" ]]; then
    v="$(conf_value QUERY_HOST)"
    p="$(conf_value QUERY_PORT)"
    if [[ -n "$p" && "$QUERY_PORT_FROM_ENV" == "0" ]]; then hport="$p"; fi
  fi
  [[ -n "$v" ]] || return 1
  if [[ "$v" =~ ^([^:[:space:]]+):([0-9]+)$ ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  elif [[ "$v" == *:* ]]; then
    return 2   # a colon that is not host:port - never silently append :4099
  else
    printf '%s %s\n' "$v" "$hport"
  fi
}

# Sets QHOST/QPORT or exits.  Keeps the three failure modes distinct:
# no hub configured / malformed address / unusable port.
resolve_or_die() {
  local hub rc
  hub="$(resolve_query_target)"; rc=$?
  case "$rc" in
    0) ;;
    2) die "bad hub address (use <ip> or <ip>:<port>)" ;;
    *) die "no hub to query. Set QUERY_HOST or write QUERY_HOST=<ip> into $HUB_CONF" ;;
  esac
  read -r QHOST QPORT <<< "$hub"
  [[ "$QPORT" =~ ^[0-9]+$ ]] || die "bad query port '$QPORT' (expected a number)"
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

# ------------------------------------------------------------------- ping
# Handled before the table query: --ping is the diagnostic for "the table
# query failed", so it must cost one round-trip and must not depend on the
# table query succeeding first.
if [[ "${MODE}" == "ping" ]]; then
  resolve_or_die
  out="$(ping_hub "$QHOST" "$QPORT")" || die "hub $QHOST:$QPORT did not answer (query-server down?)"
  [[ -n "$out" ]] || die "hub $QHOST:$QPORT connected but sent nothing"
  printf '%s\n' "$out"
  exit 0
fi

# --------------------------------------------------------- resolve the table
# The hub is the only source.  An unreachable hub is a hard error: there is no
# snapshot to fall back on any more, and inventing one would be worse than
# failing, because the result would be a connection to the wrong thing.
resolve_or_die
if live="$(query_hub "$QHOST" "$QPORT")" && [[ -n "$live" ]]; then
  parse_table "$live" || die "hub $QHOST:$QPORT returned no usable devices"
  SOURCE="live ($QHOST:$QPORT)"
else
  die "hub $QHOST:$QPORT did not answer. The hub runs ser2net + query-server; check it is up (try: console.sh --ping)"
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
key="$(echo "$TARGET" | tr 'A-Z' 'a-z')"

if [[ -n "${ALIAS_PORT[$key]+x}" ]]; then
  # Alias lookup comes FIRST: aliases wrap a-z then 1-9, so a literal "8" is a
  # real alias.  Treating it as a raw port first would silently connect to the
  # wrong endpoint (or to nothing at all).
  PORT="${ALIAS_PORT[$key]}"
  HOST="${ALIAS_HOST[$key]}"
  LABEL="${ALIAS_LABEL[$key]}"
  SLOT="$key"
elif [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  # raw port (only when no alias of that name exists)
  PORT="$TARGET"
  SLOT="port-$TARGET"
  LABEL=""
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
  need_socat
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
  need_socat
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
need_socat
exec socat - "$TCP_TARGET"