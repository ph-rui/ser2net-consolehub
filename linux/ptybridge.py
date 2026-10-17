#!/usr/bin/env python3
"""ptybridge.py - terminal <-> TCP bridge for USB-serial console ports.

Why not socat for this?  socat's `-,raw,echo=0` reaches into termios itself
and dies with "tcsetattr(...): Inappropriate ioctl for device" on any setup
where stdout is not the very same tty as stdin (| tee, script(1), captured
stdout in general).  Setting the terminal raw with termios/tty directly -
the exact same mechanism as `stty raw -echo` - is reliable on every real
terminal, and the escape (picocom-style) is just another byte we filter.

Behaviour:
  * stdin and stdout = the console; every byte is passed through untouched,
    so Ctrl+C reaches the board (u-boot / kernel boot interruption works).
  * Exit like picocom: press Ctrl+A then x (also accepts X / Ctrl+X), or
    simply Ctrl+] (0x1d).  Either way the terminal is restored.
  * To send a literal Ctrl+A to the board, press Ctrl+A twice.
  * Ctrl+A followed by any other key forwards both bytes unchanged.
  * Remote half-close or connection loss also exits cleanly.
  * Non-tty stdin (ssh -T, piped input): plain pass-through, no raw mode,
    no escape handling (Ctrl+C kills the process - same as before).

Usage: ptybridge.py HOST PORT
"""
import os
import select
import signal
import socket
import sys
import termios
import time
import tty

HOST = sys.argv[1]
PORT = int(sys.argv[2])


def restore(saved, fd=0):
    if saved is not None:
        try:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        except termios.error:
            pass


def main():
    saved = None
    s = None
    # ser2net greets every connection with its banner; normally it is
    # "USB-Enhanced-... -> host:port".  If the Windows COM open transiently
    # failed instead ("Device open failure: Permission denied" - typically
    # caused by a bare connect+close probe just before, or right after a
    # ser2net restart) the port is left clean, so reconnecting a moment
    # later succeeds.  Retry a couple of times so the user never sees it.
    for attempt in range(3):
        try:
            s = socket.create_connection((HOST, PORT), timeout=5)
        except OSError as e:
            print("error: cannot connect to %s:%s: %s" % (HOST, PORT, e),
                  file=sys.stderr)
            return 1
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.settimeout(3.0)
        first = b""
        try:
            first = s.recv(4096)
        except socket.timeout:
            pass
        s.settimeout(None)
        if first:
            os.write(1, first)
        if b"Device open failure" in first:
            print("[console] port busy on the Windows side (COM open refused)"
                  " - reconnecting ...\n", file=sys.stderr)
            s.close()
            time.sleep(2)
            continue
        break
    else:
        print("error: could not start the serial session (%s:%s)" % (HOST, PORT),
              file=sys.stderr)
        return 1

    try:
        saved = termios.tcgetattr(0)          # None / raises if stdin not a tty
        tty.setraw(0)
    except termios.error:
        saved = None                          # non-tty: plain passthrough

    def _restore(_sig=None, _frm=None):
        restore(saved)
        try:
            s.close()
        except OSError:
            pass
        sys.exit(128 if _sig else 0)

    signal.signal(signal.SIGHUP, _restore)
    signal.signal(signal.SIGTERM, _restore)

    try:
        while True:
            r, _, _ = select.select([s.fileno(), 0], [], [])
            for fd in r:
                if fd == s.fileno():
                    data = s.recv(4096)
                    if not data:              # board / ser2net side closed
                        return 0
                    os.write(1, data)
                else:                         # our stdin
                    data = os.read(0, 1)
                    if not data:              # stdin EOF
                        return 0
                    if saved is not None and data == b"\x1d":   # Ctrl+]
                        return 0
                    if saved is not None and data == b"\x01":   # Ctrl+A = escape prefix
                        # picocom-style: the second key decides.
                        #   A      -> send a literal Ctrl+A to the board
                        #   x/X/Ctrl+X -> exit
                        #   other  -> forward both bytes unchanged
                        nxt = b""
                        if select.select([0], [], [], 1.0)[0]:
                            nxt = os.read(0, 1)
                        if nxt == b"\x01":
                            s.sendall(b"\x01")
                        elif nxt in (b"x", b"X", b"\x18"):
                            return 0
                        else:
                            s.sendall(b"\x01" + nxt)
                        continue
                    s.sendall(data)
    finally:
        restore(saved)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)