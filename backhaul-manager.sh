#!/usr/bin/env bash
# Backhaul Manager for Ubuntu -- upstream Musixal/Backhaul v0.7.2
# Upload this single file to your own GitHub repository and run with sudo bash.
set -Eeuo pipefail
umask 077
BACKHAUL_VERSION='v0.7.2'
BASE='/etc/backhaul-manager'
UNIT_DIR='/etc/systemd/system'
BIN_DIR="/opt/backhaul-manager/bin/$BACKHAUL_VERSION"
BIN="$BIN_DIR/backhaul"
SELF=''
WORK=''
REPLY=''
SSH_PASS=''
SSH_HOST=''
SSH_PORT='22'
SSH_OPTIONS=()
TX_BACKUP=''
TX_NAME=''
TX_EXISTED=0
TX_ACTIVE=0
TX_ENABLED=0

say() { printf '%s\n' "$*"; }
error() { printf 'Error: %s\n' "$*" >&2; }
die() { error "$*"; exit 1; }
cleanup() {
    unset SSH_PASS
    if [[ -n "$TX_BACKUP" ]]; then
        error 'Installation interrupted; restoring the previous configuration ...'
        rollback_tunnel || true
    fi
    [[ -z "$WORK" ]] || rm -rf -- "$WORK"
}

# All parsing/rendering is centralized, without eval or sourcing user data.
bhpy() {
    python3 - "$@" <<'BHM_PY'
import sys, os, json, re, ipaddress, base64, secrets, socket, time, pathlib
cmd, *args = sys.argv[1:]
def fail(message):
    raise ValueError(message)
def ip(value):
    value = value.strip()
    if "%" in value: fail("Scoped IPv6 addresses are not supported")
    return str(ipaddress.ip_address(value))
def number(value, lo=1, hi=65535):
    if not re.fullmatch(r"[0-9]{1,6}", str(value)):
        fail("Invalid number")
    value = int(value)
    if not lo <= value <= hi:
        fail(f"Number must be between {lo} and {hi}")
    return value
def mappings(text):
    result, seen = [], set()
    for item in re.split(r"[\s,]+", text.strip()):
        if not item: continue
        parts = item.split("=")
        if len(parts) > 2: fail("Invalid port format")
        source = number(parts[0])
        if source in seen: fail("Duplicate listening port")
        seen.add(source)
        target = str(source) if len(parts) == 1 else parts[1]
        if target.isdigit():
            target = str(number(target))
        else:
            host, sep, port = target.rpartition(":")
            if not sep: fail("Invalid destination format")
            number(port)
            host = host.strip("[]")
            if host != "localhost": ip(host)
            target = f"[{host}]:{int(port)}" if ":" in host else f"{host}:{int(port)}"
        result.append(f"{source}={target}")
    if not result: fail("Enter at least one port")
    return result
def validate(m):
    if not isinstance(m, dict): fail("Invalid configuration")
    if m.get("schema") != 1: fail("Unsupported configuration version")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}", m.get("name", "")):
        fail("Tunnel name must contain 1 to 32 English letters, digits, hyphens, or underscores")
    if m.get("role") not in ("server", "client"): fail("Invalid role")
    if m.get("transport") not in ("tcp", "tcpmux"): fail("Invalid transport")
    m["iran_ip"] = ip(m.get("iran_ip", ""))
    m["control_port"] = number(m.get("control_port", ""))
    m["ports"] = mappings(",".join(m.get("ports", [])))
    if m["control_port"] in [int(x.split("=")[0]) for x in m["ports"]]:
        fail("The Backhaul connection port must differ from the service ports")
    token = m.get("token", "")
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{16,128}", token):
        fail("Token must contain 16 to 128 English letters, digits, hyphens, or underscores")
    m["pool"] = number(m.get("pool", 8), 1, 128)
    m["mux_con"] = number(m.get("mux_con", 8), 1, 128)
    return m
def load(path):
    with open(path, encoding="utf-8") as f: return validate(json.load(f))
def save(path, m):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(validate(m), f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(path, 0o600)
def addr(host, port):
    return f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
def render(m):
    role, transport = m["role"], m["transport"]
    lines = [f"[{role}]"]
    if role == "server":
        # IPv6 wildcard for an IPv6 peer; IPv4 wildcard otherwise.
        bind = "::" if ":" in m["iran_ip"] else "0.0.0.0"
        lines += [f'bind_addr = "{addr(bind, m["control_port"])}"']
    else:
        lines += [f'remote_addr = "{addr(m["iran_ip"], m["control_port"])}"']
    lines += [f'transport = "{transport}"', f'token = "{m["token"]}"',
              'keepalive_period = 75', 'nodelay = true', 'log_level = "info"',
              'sniffer = false', 'web_port = 0', 'skip_optz = true']
    if role == "server":
        lines += ['heartbeat = 40', 'channel_size = 2048']
    else:
        lines += [f'connection_pool = {m["pool"]}', 'aggressive_pool = false',
                  'dial_timeout = 10', 'retry_interval = 3']
    if transport == "tcpmux":
        if role == "server": lines += [f'mux_con = {m["mux_con"]}']
        lines += ['mux_version = 1', 'mux_framesize = 32768',
                  'mux_recievebuffer = 4194304', 'mux_streambuffer = 65536']
    if role == "server":
        lines.append('ports = ' + json.dumps(m["ports"]))
    return "\n".join(lines) + "\n"
try:
    if cmd == "ip": print(ip(args[0]))
    elif cmd == "number": print(number(args[0], int(args[1]) if len(args)>1 else 1,
                                      int(args[2]) if len(args)>2 else 65535))
    elif cmd == "name":
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}", args[0]): fail("Invalid tunnel name")
        print(args[0])
    elif cmd == "ports": print(",".join(mappings(args[0])))
    elif cmd == "new":
        path, name, role, transport, ports, host, control, token, pool, mux = args
        save(path, dict(schema=1, name=name, role=role, transport=transport,
             ports=mappings(ports), iran_ip=host, control_port=control,
             token=token or secrets.token_hex(24), pool=pool, mux_con=mux))
    elif cmd == "validate": load(args[0])
    elif cmd == "get":
        value = load(args[0])[args[1]]
        print(",".join(value) if isinstance(value, list) else value)
    elif cmd == "set":
        m = load(args[0]); m[args[1]] = args[2]; save(args[0], m)
    elif cmd == "render":
        text = render(load(args[0]))
        if len(args) > 1:
            pathlib.Path(args[1]).write_text(text, encoding="utf-8"); os.chmod(args[1], 0o600)
        else: print(text, end="")
    elif cmd == "encode":
        m = load(args[0]); m["role"] = "server"
        print(base64.urlsafe_b64encode(json.dumps(m).encode()).decode())
    elif cmd == "decode":
        encoded = args[0]
        if len(encoded) > 8192: fail("Pairing code is too large")
        m = json.loads(base64.b64decode(encoded, altchars=b"-_", validate=True))
        m["role"] = "server"; save(args[1], m)
    elif cmd == "listeners":
        m = load(args[0]); print(m["control_port"])
        if m["role"] == "server":
            for p in m["ports"]: print(p.split("=")[0])
    elif cmd == "suggest":
        root, host, ports = args
        used = {int(x.split("=")[0]) for x in mappings(ports)}
        for path in pathlib.Path(root).glob("*/metadata.json"):
            try:
                m = load(path)
                if m["iran_ip"] == host: used.add(m["control_port"])
            except Exception: pass
        p = 3080
        while p in used and p < 65535: p += 1
        if p in used: fail("No available port found")
        print(p)
    elif cmd == "control":
        # Correlate live sockets with the exact Backhaul process, not another tunnel.
        pid, role, host, port = args
        if not pid.isdigit() or int(pid) <= 0: fail("Invalid PID")
        inodes = set()
        for entry in pathlib.Path(f"/proc/{pid}/fd").iterdir():
            try:
                link = os.readlink(entry)
                if link.startswith("socket:["): inodes.add(link[8:-1])
            except OSError: pass
        def decode_endpoint(value, v6):
            address, p = value.split(":")
            raw = bytes.fromhex(address)
            raw = b"".join(raw[i:i+4][::-1] for i in range(0,len(raw),4))
            address = ipaddress.ip_address(raw)
            if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
                address = address.ipv4_mapped
            return str(address), int(p, 16)
        found = False
        for proto in ("tcp", "tcp6"):
            table = pathlib.Path(f"/proc/{pid}/net/{proto}")
            if not table.exists(): continue
            for line in table.read_text().splitlines()[1:]:
                fields = line.split()
                if len(fields) < 10 or fields[3] != "01" or fields[9] not in inodes: continue
                local_host, local_port = decode_endpoint(fields[1], proto == "tcp6")
                peer_host, peer_port = decode_endpoint(fields[2], proto == "tcp6")
                if role == "client" and peer_host == ip(host) and peer_port == int(port): found = True
                if role == "server" and local_port == int(port): found = True
        if not found: fail("No live tunnel control socket found")
    elif cmd == "tcp":
        host, port = args
        with socket.create_connection((host, int(port)), timeout=5): pass
    else: fail("Unknown internal command")
except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as e:
    print(str(e), file=sys.stderr); sys.exit(1)
BHM_PY
}

prompt() {
    local label="$1" default="${2-}"
    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$label" "$default" >&2
    else
        printf '%s: ' "$label" >&2
    fi
    IFS= read -r REPLY </dev/tty || return 1
    [[ -n "$REPLY" ]] || REPLY="$default"
}
yesno() {
    local label="$1" default="${2:-y}"
    while true; do
        prompt "$label (y/n)" "$default" || return 1
        case "${REPLY,,}" in y|yes) return 0 ;; n|no) return 1 ;; *) error 'Enter y or n.' ;; esac
    done
}
validated_prompt() {
    local label="$1" default="$2" type="$3" normalized
    while true; do
        prompt "$label" "$default" || return 1
        if normalized=$(bhpy "$type" "$REPLY"); then REPLY="$normalized"; return 0; fi
    done
}
pause() { prompt 'Press Enter to return to the menu' '' || true; }

# Keep OS metadata variables isolated from the manager.
check_system() (
    [[ "$EUID" -eq 0 ]] || die 'Run this script with sudo bash.'
    [[ -r /etc/os-release ]] || die 'Could not identify the operating system.'
    # This trusted OS file is the only sourced file.
    . /etc/os-release
    [[ "${ID:-}" == ubuntu ]] || die 'This script requires Ubuntu.'
    [[ -d /run/systemd/system ]] || die 'The server must be running systemd.'
    command -v apt-get >/dev/null || die 'apt-get was not found.'
)
bootstrap() {
    say 'Updating the package list: apt-get update'
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl tar openssl openssh-client sshpass iproute2 python3 util-linux || return 1
    install -d -m 700 "$BASE/tunnels" || return 1
    install_binary || return 1
}
install_binary() {
    local arch asset expected url actual stage
    case "$(uname -m)" in
        x86_64) arch=amd64; expected=57bf95c2eabeddb1152d2e94ac42f4310883ce0fb909ee2a57bd53503b2dabbc ;;
        aarch64|arm64) arch=arm64; expected=9a424c97ff16fc3f682e8314c418790d2b5bf3136e008edbb6cd402ea00999f6 ;;
        *) error 'Only Ubuntu amd64 and arm64 are supported.'; return 1 ;;
    esac
    if [[ -x "$BIN" && -f "$BIN_DIR/archive.sha256" ]] && \
       [[ "$(cat "$BIN_DIR/archive.sha256")" == "$expected" ]] && \
       [[ "$("$BIN" -v)" == "$BACKHAUL_VERSION" ]]; then return 0; fi
    asset="backhaul_linux_${arch}.tar.gz"
    url="https://github.com/Musixal/Backhaul/releases/download/$BACKHAUL_VERSION/$asset"
    stage=$(mktemp -d "$WORK/download.XXXXXXXX") || return 1
    say "Downloading Backhaul $BACKHAUL_VERSION for $arch ..."
    curl --fail --location --retry 3 --connect-timeout 15 --max-time 300 \
        --proto '=https' --proto-redir '=https' "$url" -o "$stage/$asset" || return 1
    actual=$(sha256sum "$stage/$asset") || return 1
    actual=${actual%% *}
    [[ "$actual" == "$expected" ]] || { error 'The downloaded file failed SHA256 verification.'; return 1; }
    tar -xzf "$stage/$asset" -C "$stage" --no-same-owner --no-same-permissions backhaul || return 1
    [[ -f "$stage/backhaul" && ! -L "$stage/backhaul" ]] || return 1
    [[ "$("$stage/backhaul" -v)" == "$BACKHAUL_VERSION" ]] || return 1
    install -d -m 755 "$BIN_DIR" || return 1
    install -m 755 "$stage/backhaul" "$BIN" || return 1
    printf '%s\n' "$expected" > "$BIN_DIR/archive.sha256" || return 1
    rm -rf -- "$stage" || return 1
}
unit_name() { printf 'backhaul-manager-%s.service' "$1"; }
owned_exists() { [[ -f "$BASE/tunnels/$1/metadata.json" ]]; }
port_busy() {
    local output
    output=$(ss -H -ltn "sport = :$1") || return 2
    [[ -n "$output" ]]
}

# Backups are persistent so a process interruption cannot erase the last copy.
rollback_tunnel() {
    local unit dir backup
    [[ -n "$TX_BACKUP" ]] || return 0
    unit=$(unit_name "$TX_NAME"); dir="$BASE/tunnels/$TX_NAME"; backup="$TX_BACKUP"
    if [[ -e "$UNIT_DIR/$unit" || "$TX_EXISTED" -eq 1 ]]; then
        systemctl stop "$unit" || { error "Could not stop the service; previous backup: $backup"; TX_BACKUP=''; return 1; }
        systemctl disable "$unit" >/dev/null 2>&1 || { error "Previous backup retained: $backup"; TX_BACKUP=''; return 1; }
    fi
    rm -rf -- "$dir" || { error "Manual recovery is required; previous backup: $backup"; TX_BACKUP=''; return 1; }
    rm -f -- "$UNIT_DIR/$unit" || { error "Manual recovery is required; previous backup: $backup"; TX_BACKUP=''; return 1; }
    if [[ "$TX_EXISTED" -eq 1 ]]; then
        cp -a "$backup/tunnel" "$dir" || { error "Manual recovery is required; previous backup: $backup"; TX_BACKUP=''; return 1; }
        if [[ -f "$backup/unit" ]]; then
            cp -a "$backup/unit" "$UNIT_DIR/$unit" || { error "Manual recovery is required; previous backup: $backup"; TX_BACKUP=''; return 1; }
        fi
    fi
    systemctl daemon-reload || { error "Previous backup retained: $backup"; TX_BACKUP=''; return 1; }
    if [[ "$TX_EXISTED" -eq 1 ]]; then
        if [[ "$TX_ENABLED" -eq 1 ]]; then
            systemctl enable "$unit" >/dev/null 2>&1 || { error "Previous backup retained: $backup"; TX_BACKUP=''; return 1; }
        fi
        if [[ "$TX_ACTIVE" -eq 1 ]]; then
            systemctl start "$unit" || { error "Previous backup retained: $backup"; TX_BACKUP=''; return 1; }
        fi
    fi
    TX_BACKUP=''
    rm -rf -- "$backup" || true
}

# Transactional install: validate before stopping, back up, restore on failure.
apply_tunnel() {
    local source="$1" name unit dir backup p code failed=0
    bhpy validate "$source" || return 1
    name=$(bhpy get "$source" name); unit=$(unit_name "$name"); dir="$BASE/tunnels/$name"
    if [[ -e "$UNIT_DIR/$unit" ]] && ! owned_exists "$name"; then
        error "Service $unit is not managed by this script; replacement cancelled."; return 1
    fi
    install -d -m 700 "$BASE/backups" || return 1
    backup=$(mktemp -d "$BASE/backups/$name.XXXXXXXX") || return 1
    TX_NAME="$name"; TX_EXISTED=0; TX_ACTIVE=0; TX_ENABLED=0
    if owned_exists "$name"; then
        TX_EXISTED=1
        cp -a "$dir" "$backup/tunnel" || return 1
        if [[ -f "$UNIT_DIR/$unit" ]]; then cp -a "$UNIT_DIR/$unit" "$backup/unit" || return 1; fi
        systemctl is-active --quiet "$unit" && TX_ACTIVE=1
        systemctl is-enabled --quiet "$unit" && TX_ENABLED=1
    fi
    TX_BACKUP="$backup"
    if [[ "$TX_EXISTED" -eq 1 ]]; then
        systemctl stop "$unit" || { rollback_tunnel || true; return 1; }
    fi
    if [[ "$(bhpy get "$source" role)" == server ]]; then
        while IFS= read -r p; do
            if port_busy "$p"; then
                error "Port $p is already in use on the Iran server."; failed=1
            else
                code=$?
                if [[ "$code" -ne 1 ]]; then error 'Could not check which ports are in use.'; failed=1; fi
            fi
        done < <(bhpy listeners "$source")
    fi
    if [[ "$failed" -eq 0 ]]; then
        install -d -m 700 "$dir" || failed=1
        install -m 600 "$source" "$dir/metadata.json" || failed=1
        bhpy render "$source" "$dir/config.toml" || failed=1
        cat > "$UNIT_DIR/$unit" <<UNIT || failed=1
[Unit]
Description=Backhaul Manager tunnel $name
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$BIN -c $dir/config.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
UNIT
        chmod 644 "$UNIT_DIR/$unit" || failed=1
        if [[ "$failed" -eq 0 ]]; then
            systemctl daemon-reload || failed=1
            systemctl enable "$unit" || failed=1
            systemctl restart "$unit" || failed=1
            sleep 2
            systemctl is-active --quiet "$unit" || failed=1
        fi
    fi
    if [[ "$failed" -ne 0 ]]; then
        error 'Setup failed; restoring the previous configuration.'
        journalctl -u "$unit" -n 12 --no-pager >&2 || true
        rollback_tunnel || true
        return 1
    fi
    TX_BACKUP=''
    rm -rf -- "$backup" || true
    say "Tunnel $name was created and will start automatically after a reboot."
}
confirm_replace() {
    local name="$1"
    if owned_exists "$name"; then
        yesno "Tunnel $name already exists. Replace it with the new tunnel?" y || return 1
    fi
}
show_pairing() {
    local meta="$1"
    say 'Copy this pairing code for manual setup on the Iran server (it contains the token):'
    bhpy encode "$meta"
}
firewall_note() {
    local meta="$1"
    say "Backhaul connection port: $(bhpy get "$meta" control_port)/TCP"
    say "Service ports on the Iran server: $(bhpy get "$meta" ports)"
    say 'These ports must be open in the Ubuntu firewall and the hosting provider firewall.'
}

collect_tunnel() {
    local out="$1" role="$2" mode="$3" old="${4-}" name transport ports host control token='' pool=8 mux=8
    local default_name=mytunnel default_transport=tcpmux default_ports='443,2083,2053,1115,1117' default_host='' default_control=3080
    if [[ -n "$old" ]]; then
        default_name=$(bhpy get "$old" name); default_transport=$(bhpy get "$old" transport)
        default_ports=$(bhpy get "$old" ports); default_host=$(bhpy get "$old" iran_ip)
        default_control=$(bhpy get "$old" control_port)
        token=$(bhpy get "$old" token); pool=$(bhpy get "$old" pool); mux=$(bhpy get "$old" mux_con)
    fi
    if [[ -n "$old" ]]; then name="$default_name"; say "Editing tunnel $name";
    else validated_prompt 'Tunnel name' "$default_name" name || return 1; name="$REPLY"; fi
    while true; do
        prompt 'Transport type (tcp or tcpmux)' "$default_transport" || return 1
        case "${REPLY,,}" in tcp|tcpmux) transport="${REPLY,,}"; break ;; *) error 'Enter tcp or tcpmux.' ;; esac
    done
    validated_prompt 'Backhaul connection port (separate from service ports)' "$default_control" number || return 1; control="$REPLY"
    say 'Separate ports with commas; for example: 443,2083 or 443=8443,2083=127.0.0.1:2083'
    validated_prompt 'Service ports' "$default_ports" ports || return 1; ports="$REPLY"
    validated_prompt 'Iran server IP' "$default_host" ip || return 1; host="$REPLY"
    if [[ "$mode" == manual || -n "$old" ]]; then
        while true; do
            prompt 'Shared token for both servers (Enter: generate automatically / keep the current token)' '' || return 1
            [[ -z "$REPLY" ]] || token="$REPLY"
            [[ -z "$token" || "$token" =~ ^[A-Za-z0-9_-]{16,128}$ ]] && break
            error 'Token must contain 16 to 128 English letters, digits, - or _.'
        done
        while true; do
            prompt 'Connection pool size (connection_pool)' "$pool" || return 1
            if pool=$(bhpy number "$REPLY" 1 128); then break; fi
        done
        if [[ "$transport" == tcpmux ]]; then
            while true; do
                prompt 'Mux connections on the Iran server (mux_con)' "$mux" || return 1
                if mux=$(bhpy number "$REPLY" 1 128); then break; fi
            done
        fi
    fi
    say "Backhaul connection port: $control/TCP"
    bhpy new "$out" "$name" "$role" "$transport" "$ports" "$host" "$control" "$token" "$pool" "$mux"
}

ssh_run() {
    # Password is provided through an anonymous FD, never argv/environment/files.
    local pass_fd status=0
    exec {pass_fd}<<<"$SSH_PASS"
    sshpass -d "$pass_fd" ssh "${SSH_OPTIONS[@]}" "root@$SSH_HOST" "$@" || status=$?
    exec {pass_fd}<&-
    return "$status"
}
ssh_upload() {
    local local_file="$1" remote_path="$2"
    ssh_run "umask 077; cat > '$remote_path'" < "$local_file"
}
setup_ssh() {
    local default_host="$1"
    validated_prompt 'Iran server IP for SSH' "$default_host" ip || return 1; SSH_HOST="$REPLY"
    validated_prompt 'Iran server SSH port' 22 number || return 1; SSH_PORT="$REPLY"
    say 'The password is visible while typing; SSH will log in as root.'
    while true; do
        prompt 'Iran server password' '' || return 1
        if [[ -n "$REPLY" ]]; then SSH_PASS="$REPLY"; REPLY=''; break; fi
        error 'The password cannot be empty.'
    done
    install -d -m 700 /root/.ssh || return 1
    SSH_OPTIONS=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new
        -o UserKnownHostsFile=/root/.ssh/known_hosts -o ConnectTimeout=10
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3
        -o PreferredAuthentications=password,keyboard-interactive
        -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR)
    ssh_run 'test "$(id -u)" = 0 && test -d /run/systemd/system' < /dev/null || {
        error 'SSH login failed; check the IP, port, password, and root login permissions.'; return 1;
    }
}
remote_exists() {
    local name="$1"
    ssh_run "test -f '$BASE/tunnels/$name/metadata.json'" < /dev/null
}
remote_install() {
    local local_meta="$1" remote_dir remote_meta name replace=no code status=0
    name=$(bhpy get "$local_meta" name)
    setup_ssh "$(bhpy get "$local_meta" iran_ip)" || { unset SSH_PASS; return 1; }
    # SSH address may be an alternative management IP; the tunnel address is retained.
    if remote_exists "$name"; then
        yesno "Tunnel $name already exists on the Iran server. Replace it?" y || { unset SSH_PASS; return 1; }
        replace=yes
    else
        code=$?
        [[ "$code" -eq 1 ]] || { error 'Could not check the tunnel on the Iran server.'; unset SSH_PASS; return 1; }
    fi
    remote_dir=$(ssh_run 'umask 077; mktemp -d /tmp/backhaul-manager.XXXXXXXX' < /dev/null) || { unset SSH_PASS; return 1; }
    [[ "$remote_dir" =~ ^/tmp/backhaul-manager\.[A-Za-z0-9]+$ ]] || { unset SSH_PASS; return 1; }
    remote_meta="$WORK/remote-metadata.json"
    bhpy decode "$(bhpy encode "$local_meta")" "$remote_meta" || { unset SSH_PASS; return 1; }
    ssh_upload "$SELF" "$remote_dir/manager.sh" || status=$?
    if [[ "$status" -eq 0 ]]; then ssh_upload "$remote_meta" "$remote_dir/metadata.json" || status=$?; fi
    if [[ "$status" -eq 0 ]]; then
        ssh_run "bash '$remote_dir/manager.sh' --remote-install '$remote_dir/metadata.json' '$replace'" < /dev/null || status=$?
    fi
    ssh_run "rm -rf -- '$remote_dir'" < /dev/null || true
    if [[ "$status" -ne 0 ]]; then
        unset SSH_PASS; error 'Installation on the Iran server failed; the client tunnel has been retained.'; return 1
    fi
    test_connection "$local_meta" yes || status=$?
    unset SSH_PASS
    return "$status"
}

fresh_log() {
    local unit="$1" invocation
    invocation=$(systemctl show "$unit" -p InvocationID --value)
    [[ "$invocation" =~ ^[a-f0-9]{32}$ ]] || return 1
    journalctl "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager -o cat
}
test_connection() {
    local meta="$1" remote="${2:-no}" role name unit host port log attempt connected=0
    role=$(bhpy get "$meta" role); name=$(bhpy get "$meta" name); unit=$(unit_name "$name")
    host=$(bhpy get "$meta" iran_ip); port=$(bhpy get "$meta" control_port)
    say 'This tunnel service will restart once to run a fresh connection test.'
    systemctl restart "$unit" || { error 'Could not restart the service for the test.'; return 1; }
    say 'Testing Backhaul connectivity and authentication (up to 45 seconds) ...'
    for ((attempt=0; attempt<15; attempt++)); do
        if systemctl is-active --quiet "$unit"; then
            log=$(fresh_log "$unit" 2>/dev/null || true)
            if [[ "$role" == client && "$log" == *'control channel established successfully'* ]] || \
               [[ "$role" == server && "$log" == *'control channel successfully established.'* ]]; then
                # A historical log alone is insufficient: check a live established control socket.
                local pid
                pid=$(systemctl show "$unit" -p MainPID --value)
                if bhpy control "$pid" "$role" "$host" "$port" 2>/dev/null; then
                    connected=1; break
                fi
            fi
        fi
        sleep 3
    done
    if [[ "$connected" -ne 1 ]]; then
        error 'Could not verify the connection; the test did not pass.'
        [[ "$role" != client ]] || bhpy tcp "$host" "$port" || true
        journalctl -u "$unit" -n 15 --no-pager >&2 || true
        say 'Check the connection port, shared token, IP, firewall, and logs.'
        return 1
    fi
    if [[ "$remote" == yes ]]; then
        # Confirm the server process is active too. Authentication is checked locally above.
        ssh_run "systemctl is-active --quiet '$unit'" < /dev/null || {
            error 'The service on the Iran server is not active.'; return 1;
        }
    fi
    say 'Tunnel connectivity and authentication succeeded.'
    if [[ "$role" == client ]]; then
        say 'Checking destination services on the outside server:'
        local mapping target target_host target_port
        IFS=',' read -r -a all_ports <<<"$(bhpy get "$meta" ports)"
        for mapping in "${all_ports[@]}"; do
            target=${mapping#*=}; target_host=127.0.0.1; target_port="$target"
            if [[ "$target" == *:* ]]; then
                target_port=${target##*:}; target_host=${target%:*}; target_host=${target_host#\[}; target_host=${target_host%\]}
            fi
            if bhpy tcp "$target_host" "$target_port" 2>/dev/null; then
                say "  $mapping: The destination service is responding."
            else
                say "  $mapping: The destination service is inactive or unreachable."
            fi
        done
    fi
}

create_tunnel() {
    local role mode=manual meta name
    prompt '1: Iran (server) / 2: Outside (client)' '' || return 1
    case "$REPLY" in 1) role=server ;; 2) role=client ;; *) error 'Invalid selection.'; return 1 ;; esac
    meta=$(mktemp "$WORK/new.XXXXXXXX.json")
    if [[ "$role" == client ]]; then
        prompt '1: Automatic / 2: Manual' 1 || return 1
        case "$REPLY" in 1) mode=auto ;; 2) mode=manual ;; *) error 'Invalid selection.'; return 1 ;; esac
        collect_tunnel "$meta" "$role" "$mode" || return 1
    else
        say 'Enter the pairing code generated on the outside server, or press Enter for manual setup.'
        prompt 'Pairing code' '' || return 1
        if [[ -n "$REPLY" ]]; then bhpy decode "$REPLY" "$meta" || return 1
        else collect_tunnel "$meta" server manual || return 1; fi
    fi
    name=$(bhpy get "$meta" name)
    confirm_replace "$name" || return 1
    apply_tunnel "$meta" || return 1
    firewall_note "$meta"
    if [[ "$role" == client ]]; then
        show_pairing "$meta"
        if yesno 'Create the tunnel on the Iran server via SSH now?' y; then
            remote_install "$meta" || return 1
        else
            say 'The client was created. Set up the matching configuration on the Iran server to connect.'
        fi
    else
        show_pairing "$meta"
        test_connection "$meta" no || return 1
    fi
}

delete_tunnel() {
    local name="$1" unit dir
    unit=$(unit_name "$name"); dir="$BASE/tunnels/$name"
    yesno "Delete tunnel $name from this server?" n || return 0
    systemctl disable --now "$unit" || return 1
    rm -f -- "$UNIT_DIR/$unit" || return 1
    rm -rf -- "$dir" || return 1
    systemctl daemon-reload || return 1
    say 'Tunnel deleted. To delete the other side, run this script on the other server.'
}
edit_tunnel() {
    local name="$1" old meta role
    old="$BASE/tunnels/$name/metadata.json"
    role=$(bhpy get "$old" role); meta=$(mktemp "$WORK/edit.XXXXXXXX.json")
    collect_tunnel "$meta" "$role" manual "$old" || return 1
    apply_tunnel "$meta" || return 1
    firewall_note "$meta"
    show_pairing "$meta"
    if [[ "$role" == client ]] && yesno 'Also replace the Iran server configuration via SSH?' y; then
        remote_install "$meta" || return 1
    else
        say 'Changes to the IP, connection port, token, or transport must match on both sides.'
    fi
}
manage_tunnels() {
    local paths=() names=() path name index choice unit meta i
    shopt -s nullglob
    paths=("$BASE"/tunnels/*/metadata.json)
    shopt -u nullglob
    [[ "${#paths[@]}" -gt 0 ]] || { say 'No tunnels created by this script were found.'; return 0; }
    for path in "${paths[@]}"; do
        name=$(bhpy get "$path" name) || continue
        names+=("$name"); unit=$(unit_name "$name")
        say "${#names[@]}) $name | $(bhpy get "$path" role) | $(bhpy get "$path" transport) | $(systemctl is-active "$unit" || true)"
    done
    [[ "${#names[@]}" -gt 0 ]] || return 1
    prompt 'Tunnel number (0: Back)' 0 || return 1
    index=$(bhpy number "$REPLY" 0 "${#names[@]}") || return 1
    [[ "$index" -ne 0 ]] || return 0
    name="${names[index-1]}"; unit=$(unit_name "$name"); meta="$BASE/tunnels/$name/metadata.json"
    while true; do
        say "Manage $name"
        say '1) Edit tunnel'
        say '2) Delete tunnel'
        say '3) Status and logs'
        say '4) Restart'
        say '5) Test connection'
        say '6) Show pairing code'
        say '0) Back'
        prompt 'Selection' 0 || return 1; choice="$REPLY"
        case "$choice" in
            1) edit_tunnel "$name" || error 'Editing did not complete.' ;;
            2) delete_tunnel "$name" || return 1; owned_exists "$name" || return 0 ;;
            3) systemctl status "$unit" --no-pager || true; journalctl -u "$unit" -n 25 --no-pager || true ;;
            4) systemctl restart "$unit" || return 1; say 'Service restarted.' ;;
            5) test_connection "$meta" no || true ;;
            6) show_pairing "$meta" ;;
            0) return 0 ;;
            *) error 'Invalid selection.' ;;
        esac
    done
}

main() {
    local option=''
    case "${1-}" in
        -h|--help)
            say 'Backhaul Manager: sudo bash backhaul-manager.sh'
            say 'Ubuntu amd64/arm64; Backhaul v0.7.2; Iran=server, Outside=client.'; return 0 ;;
        ''|--remote-install) ;;
        *) die 'Unknown option; use --help.' ;;
    esac
    check_system
    SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
    [[ -f "$SELF" ]] || die 'Download the script first, then run it with bash.'
    WORK=$(mktemp -d /tmp/backhaul-manager-local.XXXXXXXX)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    # Hold one lock per host through bootstrap and menu, including remote installs.
    exec 9>/run/lock/backhaul-manager.lock
    flock -n 9 || die 'Another instance of Backhaul Manager is already running on this server.'
    if [[ "${1-}" != --remote-install ]]; then
        [[ -r /dev/tty ]] || die 'The menu requires an interactive terminal.'
    else
        [[ "$#" -eq 3 && -f "$2" ]] || die 'Invalid remote installation request.'
        [[ "$3" == yes || "$3" == no ]] || die 'Invalid replacement option.'
    fi
    bootstrap || die 'Failed to install dependencies or Backhaul.'
    if [[ "${1-}" == --remote-install ]]; then
        bhpy validate "$2" || die 'The received configuration is invalid.'
        [[ "$(bhpy get "$2" role)" == server ]] || die 'The installation request must use the server role.'
        if owned_exists "$(bhpy get "$2" name)" && [[ "$3" != yes ]]; then
            die 'The tunnel already exists; replacement was not authorized.'
        fi
        apply_tunnel "$2" || die 'Failed to install the tunnel on the Iran server.'
        firewall_note "$2"
        return 0
    fi
    while true; do
        say ''
        say "Backhaul Manager $BACKHAUL_VERSION"
        say '1) Create tunnel'
        say '2) Manage existing tunnels'
        say '3) Exit'
        prompt 'Selection' '' || return 0; option="$REPLY"
        case "$option" in
            1) create_tunnel || error 'The operation did not complete; check the message above.'; pause ;;
            2) manage_tunnels || error 'Tunnel management failed.' ;;
            3) return 0 ;;
            *) error 'Invalid selection.' ;;
        esac
    done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
