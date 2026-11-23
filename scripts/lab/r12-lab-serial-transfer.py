#!/usr/bin/env python3
"""R12: transfer the verified Stage4 script to LAB204 over its EXISTING serial socket.

Host: Proxmox root. Guest: interactive root shell on LAB204 ttyS0.
Never starts/stops a VM, changes PVE configuration, applies namespaces, or touches VM202.
"""
import base64
import gzip
import hashlib
import os
import select
import socket
import subprocess
import sys
import time

VM = "204"
SRC = "/root/r12-lab-stage4.sh"
SOCKET = "/var/run/qemu-server/204.serial0"
SHA256 = "e1136ec11649921d4ee1765f96b9ff91d0c84f38352bc2b5ddc13cfabe3568f4"
DEST = "/root/r12-lab-stage4.sh"
DELIM = "R12_STAGE4_DATA_EOF"

def stop(reason):
    raise RuntimeError("STOP: " + reason)

def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()

def preflight():
    if os.geteuid() != 0:
        stop("Proxmox root required")
    if run("qm", "status", "202") != "status: running":
        stop("VM202 is not running")
    if run("qm", "status", VM) != "status: running":
        stop("VM204 is not running")
    config = run("qm", "config", VM)
    if any(line.startswith(("net0:", "net1:", "net2:", "net3:", "net4:")) for line in config.splitlines()):
        stop("LAB204 has a PVE NIC")
    if "serial0: socket" not in config:
        stop("LAB204 serial0 socket absent")
    clients = run("ps", "-eo", "args")
    for line in clients.splitlines():
        if "/usr/sbin/qm terminal 204" in line or ("socat UNIX-CONNECT:" + SOCKET) in line:
            stop("another serial terminal is attached; exit it first (Ctrl+O)")
    data = open(SRC, "rb").read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        stop("host script SHA256 mismatch")
    if not os.path.exists(SOCKET):
        stop("serial socket missing")
    return data

def main():
    data = preflight()
    packed = base64.b64encode(gzip.compress(data, mtime=0)).decode("ascii")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(3)
    sock.connect(SOCKET)
    sock.setblocking(False)
    output = bytearray()

    def receive(pause=0.04):
        timeout = pause
        while True:
            readable, _, _ = select.select([sock], [], [], timeout)
            if not readable:
                return
            buf = sock.recv(16384)
            if not buf:
                stop("serial disconnected")
            output.extend(buf)
            if len(output) > 32768:
                del output[:-16384]
            timeout = 0

    def send(line, delay=0.08):
        buf = (line + "\n").encode("ascii")
        while buf:
            _, writable, _ = select.select([], [sock], [], 3)
            if not writable:
                stop("serial write timeout")
            written = sock.send(buf)
            if written <= 0:
                stop("serial write failed")
            buf = buf[written:]
        time.sleep(delay)
        receive()

    def await_marker(marker, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if marker.encode() in output:
                return True
            receive(0.2)
        return False

    try:
        # This command must run at an already authenticated root shell in LAB204.
        send("stty -echo", 0.4)
        send("printf 'R12_SERIAL_UID_%s\\n' \"$(id -u)\"", 0.2)
        if not await_marker("R12_SERIAL_UID_0"):
            stop("no responsive root shell on guest serial; no transfer attempted")
        send("umask 077; set -o pipefail")
        send("base64 -d <<'" + DELIM + "' | gzip -dc > " + DEST, 0.15)
        for start in range(0, len(packed), 64):
            send(packed[start:start + 64], 0.10)
        send(DELIM, 0.3)
        verify = (
            "if printf '%s  %s\\n' " + SHA256 + " " + DEST +
            " | sha256sum -c - && bash -n " + DEST + " && bash " + DEST + 
            " check; then printf 'R12_STAGE4_CHECK_PASS\\n'; " +
            "else printf 'R12_STAGE4_CHECK_STOP\\n'; fi"
        )
        send(verify, 0.2)
        if not (await_marker("R12_STAGE4_CHECK_PASS", 10) or
                await_marker("R12_STAGE4_CHECK_STOP", 1)):
            stop("no preflight result; inspect guest serial interactively")
        success = b"R12_STAGE4_CHECK_PASS" in output and b"PREFLIGHT_PASS" in output
        send("stty echo", 0.2)
        print(output.decode("utf-8", errors="replace")[-1800:])
        if not success:
            stop("guest checksum/syntax/preflight failed; no apply performed")
        print("HOST_TRANSFER_OK: LAB204 check passed; apply NOT performed")
    finally:
        sock.close()

if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, RuntimeError) as exc:
        print(exc, file=sys.stderr)
        sys.exit(1)
