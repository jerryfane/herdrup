#!/usr/bin/env bash
# Temporary hosted-Linux evidence only. Never use a live account or server.
set +x
set -euo pipefail
umask 077

app=$(realpath "${1:?app checkout required}")
evidence=$(realpath "${2:?evidence checkout required}")
output=$(realpath -m "${3:?sanitized output directory required}")
[[ $EUID == 0 ]] || { echo 'Run only inside the disposable CI container.' >&2; exit 1; }
app_sha=$(git -C "$app" rev-parse HEAD)
[[ $app_sha == "${GRAM_EVIDENCE_EXPECTED_APP_SHA:?expected app SHA required}" ]]
case "$app_sha" in
  9876878edea599b347a9788c387107775d848fdc|ea7f4f5c9c505f449c592b18c6bd05c1d5d7f7f3) ;;
  *) echo 'Unexpected production source revision.' >&2; exit 1 ;;
esac
mkdir -p "$output"
state=$(mktemp -d /tmp/gram-citadel.XXXXXXXX)
chmod 711 "$state"
account="gram$(openssl rand -hex 5)"
account_created=0
sshd_pid=''
proxy_pid=''
server_pid=''
wrapper="$state/account/.local/bin/herdr"

stop_scenario() {
  if [[ -x $wrapper ]]; then
    timeout --kill-after=2s 10s runuser -u "$account" -- "$wrapper" server stop >/dev/null 2>&1 || true
  fi
  if (( account_created )); then
    pkill -TERM -u "$account" 2>/dev/null || true
    sleep 0.2
    pkill -KILL -u "$account" 2>/dev/null || true
  fi
  if [[ -n $server_pid ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=''
  fi
}
cleanup() {
  set +e
  stop_scenario
  for pid in "$proxy_pid" "$sshd_pid"; do
    if [[ -n $pid ]]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    fi
  done
  if (( account_created )); then userdel "$account" >/dev/null 2>&1; fi
  rm -rf -- "$state"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Record source identity before injecting the single temporary XCTest.
python3 - "$app" "$app_sha" "$state/provenance.json" <<'PY'
import hashlib, json, pathlib, sys
root, sha, target = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
paths = ["Package.resolved"] + ["Sources/HerdrKit/" + name + ".swift" for name in
    ("CitadelTransport", "GramUploadChannel", "HerdrClient", "RequestChannel")]
files = {name: {"present": (root / name).is_file(),
                "sha256": hashlib.sha256((root / name).read_bytes()).hexdigest()
                if (root / name).is_file() else None} for name in paths}
target.write_text(json.dumps({"git_rev_parse_HEAD": sha, "files": files,
    "configuration": "release with -enable-testing", "platform": "hosted Linux / swift:6.1",
    "not_device_or_relay_evidence": True}, indent=2) + "\n")
PY
cp "$evidence/Tests/HerdrKitTests/GramRealCitadelEvidenceTests.swift" \
   "$app/Tests/HerdrKitTests/GramRealCitadelEvidenceTests.swift"
cd "$app"
echo 'Building production app tests once; no existing test suite is executed.'
timeout --kill-after=15s 1080s swift build -c release --build-tests --force-resolved-versions -Xswiftc -enable-testing

mkdir -p "$state/keys" "$state/bin" "$state/account/.ssh" "$state/account/.local/bin"
chmod 755 "$state/bin"
useradd --user-group --no-create-home --home-dir "$state/account" --shell /bin/sh "$account"
account_created=1
# OpenSSH rejects locked accounts even with authorized_keys. Set an unknown random
# password hash, then disable every password authentication method in sshd.
password_hash=$(openssl rand -hex 32 | openssl passwd -6 -stdin)
printf '%s:%s\n' "$account" "$password_hash" | chpasswd -e
unset password_hash
ssh-keygen -q -t ed25519 -N '' -C gram-evidence-client -f "$state/keys/client"
ssh-keygen -q -t ed25519 -N '' -C gram-evidence-host -f "$state/keys/host"
cp "$state/keys/client.pub" "$state/account/.ssh/authorized_keys"
chown -R "$account:$account" "$state/account"
chmod 700 "$state/account" "$state/account/.ssh"
chmod 600 "$state/account/.ssh/authorized_keys"
mkdir -p /run/sshd
cat > "$state/sshd_config" <<EOF
Port 2222
ListenAddress 127.0.0.1
AddressFamily inet
HostKey $state/keys/host
PidFile $state/sshd.pid
AuthorizedKeysFile $state/account/.ssh/authorized_keys
AllowUsers $account
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM no
StrictModes yes
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
PermitUserRC no
UseDNS no
LogLevel DEBUG3
EOF
/usr/sbin/sshd -D -f "$state/sshd_config" -E "$state/sshd.log" &
sshd_pid=$!
python3 "$evidence/Tools/ci/gram-evidence-wanproxy.py" 2223 2222 120 100 > "$state/proxy.log" 2>&1 &
proxy_pid=$!
python3 - <<'PY'
import socket, time
for port in (2222, 2223):
    for attempt in range(100):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                break
        except OSError:
            time.sleep(0.1)
    else:
        raise SystemExit("Loopback listener readiness timed out")
PY

result=0
for scenario in old new; do
  case "$scenario" in
    old)
      server_sha=8a9d5df234fcfca6c256a0ba24877b267c2008e3
      release=preview-2026-10-29-8a9d5df234fc
      checksum=e1bc54b0392aa7e6dfe3b5394929293401d46b0148be21e131e07108dda6d438
      ;;
    new)
      server_sha=d175b50315244e0290e7cf2244647d0d4fb99d26
      release=preview-2026-10-29-d175b5031524
      checksum=3354c75cdd699a8955b329d67c09291da7f7c9c0fbe8927de0ac6187d51d1a34
      ;;
  esac
  echo "Preparing $scenario server with verified public release binary."
  binary="$state/bin/herdr-$scenario"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 120 \
    "https://github.com/jerryfane/herdr/releases/download/$release/herdr-linux-x86_64" -o "$binary"
  printf '%s  %s\n' "$checksum" "$binary" | sha256sum --check --status
  chmod 755 "$binary"
  sandbox="$state/$scenario"
  mkdir -p "$sandbox"/{config,state,data,cache,run} "$state/client-$scenario"
  chown -R "$account:$account" "$sandbox"
  # The production /bin/sh command resolves ~/.local/bin/herdr. This wrapper
  # replaces the ENTIRE inherited environment for both server and API bridges.
  # No root HOME, production socket, config, or inherited HERDR_* can leak in.
  cat > "$wrapper" <<EOF
#!/bin/sh
cd '$sandbox'
classify_bridge() {
  if [ "\${1-}" = --session ]; then shift 2; fi
  case "\${1-}:\${2-}" in
    remote-api-bridge:*) printf '%s\\n' remote-api-bridge ;;
    api-bridge:--multi) printf '%s\\n' api-bridge-multi ;;
    api-bridge:--duplex) printf '%s\\n' api-bridge-duplex ;;
    api-bridge:*) printf '%s\\n' api-bridge-request ;;
    *) printf '%s\\n' other ;;
  esac
}
# Only fixed categories are retained; never arguments or encoded request data.
classify_bridge "\$@" >> '$sandbox/bridge-categories'
exec /usr/bin/env -i HOME='$sandbox' XDG_CONFIG_HOME='$sandbox/config' \\
  XDG_STATE_HOME='$sandbox/state' XDG_DATA_HOME='$sandbox/data' \\
  XDG_CACHE_HOME='$sandbox/cache' XDG_RUNTIME_DIR='$sandbox/run' \\
  PATH=/usr/local/bin:/usr/bin:/bin TERM=xterm-256color LANG=C.UTF-8 \\
  '$binary' "\$@"
EOF
  chmod 755 "$wrapper"
  chown "$account:$account" "$wrapper"
  timeout --kill-after=2s 10s runuser -u "$account" -- "$wrapper" --version > "$state/version-$scenario" 2>&1
  # Same startup/socket contract as the existing sandbox bench.py. A fresh
  # config has federation.listen=false, so herdr itself exposes only Unix IPC.
  timeout --kill-after=5s 420s runuser -u "$account" -- "$wrapper" server > "$state/server-$scenario.log" 2>&1 &
  server_pid=$!
  python3 - "$sandbox/config/herdr/herdr.sock" <<'PY'
import socket, sys, time
for attempt in range(200):
    try:
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(0.1)
            client.connect(sys.argv[1])
        break
    except OSError:
        time.sleep(0.1)
else:
    raise SystemExit("Sandbox Unix socket readiness timed out")
# Assert our two listener bindings. Docker's own embedded DNS may separately
# listen on 127.0.0.11; it is not a benchmark listener or a herdr endpoint.
seen = set()
for table in ("/proc/net/tcp", "/proc/net/tcp6"):
    with open(table) as source:
        for line in list(source)[1:]:
            fields = line.split()
            address, port = fields[1].split(":")
            port = int(port, 16)
            if fields[3] == "0A" and port in (2222, 2223):
                if address != "0100007F":
                    raise SystemExit("Benchmark listener is not IPv4 loopback")
                seen.add(port)
if seen != {2222, 2223}:
    raise SystemExit("Benchmark listener disappeared")
PY
  # Offset separates each scenario's observations without truncating an open log.
  log_offset=$(stat -c %s "$state/sshd.log")
  receipt="$state/receipt-$scenario.json"
  : > "$sandbox/bridge-categories"
  echo "Measuring $scenario server: real Citadel Linux, emulated RTT120ms/100Mbit."
  status=0
  HOME="$state/client-$scenario" XDG_CONFIG_HOME="$state/client-$scenario/config" \
    XDG_STATE_HOME="$state/client-$scenario/state" XDG_DATA_HOME="$state/client-$scenario/data" \
    XDG_CACHE_HOME="$state/client-$scenario/cache" XDG_RUNTIME_DIR="$state/client-$scenario/run" \
    GRAM_EVIDENCE_ENABLE=1 GRAM_EVIDENCE_HOST=127.0.0.1 GRAM_EVIDENCE_PORT=2223 \
    GRAM_EVIDENCE_USER="$account" GRAM_EVIDENCE_PRIVATE_KEY_FILE="$state/keys/client" \
    GRAM_EVIDENCE_APP_SHA="$app_sha" GRAM_EVIDENCE_SERVER_SHA="$server_sha" \
    GRAM_EVIDENCE_RECEIPT="$receipt" GRAM_EVIDENCE_SIZES=10 \
    timeout --kill-after=15s 300s swift test -c release --skip-build -Xswiftc -enable-testing \
      --filter 'HerdrKitTests.GramRealCitadelEvidenceTests/testRealCitadelRoundTrip' \
      > "$state/test-$scenario.log" 2>&1 || status=$?
  stop_scenario
  scenario_status=0
  python3 - "$state" "$output" "$scenario" "$server_sha" "$checksum" "$log_offset" "$status" <<'PY' || scenario_status=$?
import hashlib, json, pathlib, re, sys
state, output = map(pathlib.Path, sys.argv[1:3])
scenario, server_sha, checksum, offset, status = sys.argv[3:]
status = int(status)
provenance = json.loads((state / "provenance.json").read_text())
version = (state / ("version-" + scenario)).read_text(errors="replace")
# Version is printable, bounded metadata, not arbitrary server/sshd diagnostics.
version = "".join(c for c in version if c.isprintable() or c == "\n")[:4096].strip()
actual_checksum = hashlib.sha256((state / "bin" / ("herdr-" + scenario)).read_bytes()).hexdigest()
metadata = {"app": provenance, "server_sha": server_sha,
            "binary_sha256": actual_checksum, "expected_binary_sha256": checksum,
            "server_version_output": version, "test_exit_code": status}
(output / (scenario + "-provenance.json")).write_text(json.dumps(metadata, indent=2) + "\n")
with (state / "sshd.log").open("rb") as source:
    source.seek(int(offset))
    log = source.read().decode("utf-8", errors="replace")
pattern = r"server_input_channel_open: ctype (\S+) rchan (\d+) win (\d+) max (\d+)"
channels = [{"type": kind, "client_channel_id": int(channel),
             "client_receive_window_bytes": int(window), "client_max_packet_bytes": int(packet)}
            for kind, channel, window, packet in re.findall(pattern, log)]
allowed_categories = ("remote-api-bridge", "api-bridge-multi", "api-bridge-duplex",
                      "api-bridge-request", "other")
categories = (state / scenario / "bridge-categories").read_text().splitlines()
category_counts = {category: categories.count(category) for category in allowed_categories}
window_evidence = {"app_sha": provenance["git_rev_parse_HEAD"], "server_sha": server_sha,
    "source": "OpenSSH DEBUG3 server_input_channel_open: client-advertised receive windows",
    "status": "observed" if channels else "not_observed", "channels": channels,
    "bridge_command_category_counts": category_counts}
(output / (scenario + "-ssh-windows.json")).write_text(json.dumps(window_evidence, indent=2) + "\n")
receipt = state / ("receipt-" + scenario + ".json")
if receipt.is_file():
    measurement = json.loads(receipt.read_text())
    measurement["provenance"] = metadata
else:
    measurement = {"status": "failed", "stage": "test_receipt_missing", "provenance": metadata}
(output / (scenario + "-measurement.json")).write_text(json.dumps(measurement, indent=2) + "\n")
# A zero SwiftPM exit with no matching test is not successful evidence.
if status != 0 or not receipt.is_file() or measurement.get("status") != "passed":
    raise SystemExit(1)
PY
  if (( status != 0 || scenario_status != 0 )); then
    echo "$scenario scenario failed; sanitized evidence retained (private logs not uploaded)." >&2
    result=1
  else
    echo "$scenario scenario completed; sanitized evidence retained."
  fi
done
exit "$result"
