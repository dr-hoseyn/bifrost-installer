#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Bifrost Manager (clean + reliable config editing)
# - Installs/updates files from GitHub
# - Configures YAML keys: listen_ip, src_ip, dst_ip, address, protocol
# - Edit full config with nano
# - systemd runs as root (required by bifrost)
# ============================================================

REPO="dr-hoseyn/bifrost-installer"
BRANCH="main"
REPO_DIR="/opt/bifrost-installer"

INSTALL_DIR="/opt/bifrost"
BIN_PATH="${INSTALL_DIR}/bifrost"

SERVICE_NAME="bifrost"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

CONFIG_DIR="${INSTALL_DIR}/configs"
CONFIG_FILE_NAME="config.yaml"   # change if needed
CONFIG_FILE="${CONFIG_DIR}/${CONFIG_FILE_NAME}"

ADDRESS_IR="10.10.0.1/24"
ADDRESS_OUT="10.10.0.2/24"

HR="----------------------------------------"

# -------------------------
# UI helpers
# -------------------------
say()  { echo -e "$*"; }
ok()   { echo -e "✅ $*"; }
warn() { echo -e "⚠️  $*"; }
err()  { echo -e "❌ $*" >&2; }

pause() {
  echo
  read -rp "Press Enter to continue..." _ </dev/tty || true
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Run as root:"
    echo "  sudo bash manager.sh"
    exit 1
  fi
}

# -------------------------
# deps / repo sync
# -------------------------
ensure_deps() {
  require_root

  if ! need_cmd git; then
    say "Installing git..."
    apt-get update -y
    apt-get install -y git
  fi

  if ! need_cmd curl && ! need_cmd wget; then
    say "Installing curl..."
    apt-get update -y
    apt-get install -y curl
  fi

  if ! need_cmd nano; then
    say "Installing nano..."
    apt-get update -y
    apt-get install -y nano
  fi

  if ! need_cmd python3; then
    say "Installing python3 (for reliable YAML editing)..."
    apt-get update -y
    apt-get install -y python3
  fi
}

sync_repo() {
  ensure_deps
  if [ -d "$REPO_DIR/.git" ]; then
    say "Syncing repository..."
    git -C "$REPO_DIR" fetch --all --prune
    git -C "$REPO_DIR" reset --hard "origin/$BRANCH"
  else
    say "Cloning repository..."
    rm -rf "$REPO_DIR"
    git clone --branch "$BRANCH" "https://github.com/$REPO.git" "$REPO_DIR"
  fi
}

# -------------------------
# system helpers
# -------------------------
get_public_ip() {
  local ip=""
  if need_cmd curl; then
    ip="$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$ip" ] || ip="$(curl -4 -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [ -z "$ip" ] && need_cmd wget; then
    ip="$(wget -qO- --timeout=3 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$ip" ] || ip="$(wget -qO- --timeout=3 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [ -z "$ip" ] && need_cmd ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 || true)"
  fi
  echo "$ip"
}

service_status_short() {
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "running"
  else
    echo "stopped"
  fi
}

current_version() {
  if [ -x "$BIN_PATH" ]; then
    if "$BIN_PATH" --version >/dev/null 2>&1; then
      "$BIN_PATH" --version 2>/dev/null | head -n 1
      return
    fi
    if "$BIN_PATH" -v >/dev/null 2>&1; then
      "$BIN_PATH" -v 2>/dev/null | head -n 1
      return
    fi
    echo "Installed (version unknown)"
  else
    echo "Not installed"
  fi
}

# -------------------------
# YAML helpers (reliable)
# - Replace first occurrence anywhere in file (any indentation)
# - Keep indentation and inline comments
# - If key not found -> append at end (top-level)
# -------------------------
yaml_get_first() {
  local file="$1" key="$2"
  [ -f "$file" ] || { echo ""; return 0; }
  python3 - "$file" "$key" <<'PY'
import re, sys
path, key = sys.argv[1], sys.argv[2]
txt = open(path, "r", encoding="utf-8", errors="ignore").read().splitlines()
pat = re.compile(rf'^(\s*){re.escape(key)}\s*:\s*(.*)$')
for line in txt:
    m = pat.match(line)
    if m:
        val = m.group(2)
        # strip inline comments (best effort)
        val = val.split('#', 1)[0].strip()
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        print(val)
        sys.exit(0)
print("")
PY
}

yaml_set_first() {
  local file="$1" key="$2" value="$3" quoted="$4"  # quoted: yes/no
  [ -f "$file" ] || { err "Config file not found: $file"; return 1; }

  python3 - "$file" "$key" "$value" "$quoted" <<'PY'
import re, sys
path, key, value, quoted = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(path, "r", encoding="utf-8", errors="ignore").read().splitlines(True)

pat = re.compile(rf'^(\s*){re.escape(key)}\s*:\s*(.*)$')
new_lines = []
done = False

def make_value(v):
    if quoted == "yes":
        return f"\"{v}\""
    return v

for line in lines:
    if not done:
        m = pat.match(line)
        if m:
            indent = m.group(1)
            rest = m.group(2)
            # keep inline comment if exists
            comment = ""
            if "#" in rest:
                before, after = rest.split("#", 1)
                comment = " #" + after.rstrip("\n")
            newline = "\n" if line.endswith("\n") else ""
            new_lines.append(f"{indent}{key}: {make_value(value)}{comment}{newline}")
            done = True
            continue
    new_lines.append(line)

if not done:
    # append as top-level at end (best effort)
    if len(new_lines) and not new_lines[-1].endswith("\n"):
        new_lines[-1] = new_lines[-1] + "\n"
    new_lines.append(f"\n{key}: {make_value(value)}\n")

open(path, "w", encoding="utf-8").write("".join(new_lines))
PY
}

# -------------------------
# Install/update files
# -------------------------
install_files() {
  require_root
  sync_repo

  if [ ! -f "$REPO_DIR/bifrost" ]; then
    err "bifrost binary not found in repo root."
    exit 1
  fi

  say "Installing files into ${INSTALL_DIR} ..."
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$REPO_DIR/bifrost" "$BIN_PATH"

  rm -rf "$CONFIG_DIR"
  mkdir -p "$CONFIG_DIR"
  if [ -d "$REPO_DIR/configs" ]; then
    cp -R "$REPO_DIR/configs/." "$CONFIG_DIR/"
  else
    warn "configs/ not found in repo; created empty configs dir."
  fi

  ok "Files installed."
}

install_systemd_service() {
  require_root
  say "Installing systemd service (runs as root)..."
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Bifrost Service
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} ${CONFIG_FILE}
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  ok "systemd service installed."
}

# -------------------------
# Interactive config
# -------------------------
choose_location_address() {
  while true; do
    echo
    say "Server location:"
    say "  1) Iran        -> address: ${ADDRESS_IR}"
    say "  2) Outside Iran-> address: ${ADDRESS_OUT}"
    read -rp "Choose (1/2): " loc </dev/tty || true
    case "${loc:-}" in
      1) echo "$ADDRESS_IR"; return 0 ;;
      2) echo "$ADDRESS_OUT"; return 0 ;;
      *) warn "Invalid choice. Enter 1 or 2." ;;
    esac
  done
}

configure_interactive() {
  require_root

  if [ ! -f "$CONFIG_FILE" ]; then
    err "Config file not found: $CONFIG_FILE"
    err "Check CONFIG_FILE_NAME in manager.sh"
    return 1
  fi

  local auto_ip cur_listen cur_src cur_dst cur_addr cur_proto
  auto_ip="$(get_public_ip)"
  [ -n "$auto_ip" ] || warn "Could not detect server public IP automatically."

  cur_listen="$(yaml_get_first "$CONFIG_FILE" "listen_ip")"
  cur_src="$(yaml_get_first "$CONFIG_FILE" "src_ip")"
  cur_dst="$(yaml_get_first "$CONFIG_FILE" "dst_ip")"
  cur_addr="$(yaml_get_first "$CONFIG_FILE" "address")"
  cur_proto="$(yaml_get_first "$CONFIG_FILE" "protocol")"

  echo
  say "Config file:"
  say "  $CONFIG_FILE"
  say "$HR"
  [ -n "$cur_addr" ]   && say "Current address:   $cur_addr"
  [ -n "$cur_listen" ] && say "Current listen_ip: $cur_listen"
  [ -n "$cur_src" ]    && say "Current src_ip:    $cur_src"
  [ -n "$cur_dst" ]    && say "Current dst_ip:    $cur_dst"
  [ -n "$cur_proto" ]  && say "Current protocol:  $cur_proto"
  say "$HR"

  # address from location
  local address
  address="$(choose_location_address)"

  # listen_ip (Enter = auto)
  local listen_ip in_listen
  while true; do
    if [ -n "$auto_ip" ]; then
      read -rp "listen_ip [auto: ${auto_ip}] (Enter = auto): " in_listen </dev/tty || true
      listen_ip="${in_listen:-$auto_ip}"
    else
      read -rp "listen_ip (required): " listen_ip </dev/tty || true
    fi
    [ -n "${listen_ip:-}" ] && break
    warn "listen_ip cannot be empty."
  done

  # src_ip (Enter = auto)
  local src_ip in_src
  while true; do
    if [ -n "$auto_ip" ]; then
      read -rp "src_ip [auto: ${auto_ip}] (Enter = auto): " in_src </dev/tty || true
      src_ip="${in_src:-$auto_ip}"
    else
      read -rp "src_ip (required): " src_ip </dev/tty || true
    fi
    [ -n "${src_ip:-}" ] && break
    warn "src_ip cannot be empty."
  done

  # dst_ip (Enter keep current)
  local dst_ip in_dst
  if [ -n "$cur_dst" ]; then
    read -rp "dst_ip (current: ${cur_dst}) (Enter = keep current): " in_dst </dev/tty || true
    dst_ip="${in_dst:-$cur_dst}"
  else
    while true; do
      read -rp "dst_ip (required): " dst_ip </dev/tty || true
      [ -n "${dst_ip:-}" ] && break
      warn "dst_ip cannot be empty."
    done
  fi

  # protocol (Enter keep current; else default 58)
  local protocol in_proto
  if [ -n "$cur_proto" ]; then
    read -rp "protocol (current: ${cur_proto}) (Enter = keep current): " in_proto </dev/tty || true
    protocol="${in_proto:-$cur_proto}"
  else
    read -rp "protocol [default: 58]: " in_proto </dev/tty || true
    protocol="${in_proto:-58}"
  fi

  echo
  ok "Applying:"
  say "  address   = $address"
  say "  listen_ip = $listen_ip"
  say "  src_ip    = $src_ip"
  say "  dst_ip    = $dst_ip"
  say "  protocol  = $protocol"
  echo

  # IMPORTANT: replace existing keys wherever they are (any indentation)
  yaml_set_first "$CONFIG_FILE" "address"   "$address"   "yes"
  yaml_set_first "$CONFIG_FILE" "listen_ip" "$listen_ip" "yes"
  yaml_set_first "$CONFIG_FILE" "src_ip"    "$src_ip"    "yes"
  yaml_set_first "$CONFIG_FILE" "dst_ip"    "$dst_ip"    "yes"
  yaml_set_first "$CONFIG_FILE" "protocol"  "$protocol"  "no"

  ok "Config updated successfully."
}

edit_config_nano() {
  require_root
  if [ ! -f "$CONFIG_FILE" ]; then
    err "Config file not found: $CONFIG_FILE"
    return 1
  fi
  nano "$CONFIG_FILE"

  echo
  read -rp "Restart service now? (y/N): " ans </dev/tty || true
  case "${ans:-N}" in
    y|Y)
      systemctl reset-failed "$SERVICE_NAME" || true
      systemctl restart "$SERVICE_NAME" || true
      systemctl --no-pager status "$SERVICE_NAME" || true
      ;;
    *) ;;
  esac
}

# -------------------------
# Actions
# -------------------------
action_install_update() {
  require_root
  say "$HR"
  say "Install / Update"
  say "$HR"
  install_files
  configure_interactive
  install_systemd_service
  systemctl reset-failed "$SERVICE_NAME" || true
  systemctl restart "$SERVICE_NAME" || true
  echo
  systemctl --no-pager status "$SERVICE_NAME" || true
  pause
}

action_config_only() {
  require_root
  say "$HR"
  say "Configure only"
  say "$HR"
  configure_interactive
  systemctl reset-failed "$SERVICE_NAME" || true
  systemctl restart "$SERVICE_NAME" || true
  echo
  systemctl --no-pager status "$SERVICE_NAME" || true
  pause
}

action_start()   { require_root; systemctl start "$SERVICE_NAME" || true; systemctl --no-pager status "$SERVICE_NAME" || true; pause; }
action_stop()    { require_root; systemctl stop "$SERVICE_NAME" || true; systemctl --no-pager status "$SERVICE_NAME" || true; pause; }
action_restart() { require_root; systemctl reset-failed "$SERVICE_NAME" || true; systemctl restart "$SERVICE_NAME" || true; systemctl --no-pager status "$SERVICE_NAME" || true; pause; }

action_status() {
  require_root
  systemctl --no-pager status "$SERVICE_NAME" || true
  pause
}

action_logs() {
  require_root
  say "Press Ctrl+C to exit logs."
  journalctl -u "$SERVICE_NAME" -f
}

action_show_config_summary() {
  require_root
  echo
  say "Config file: $CONFIG_FILE"
  if [ -f "$CONFIG_FILE" ]; then
    echo
    say "address:   $(yaml_get_first "$CONFIG_FILE" address)"
    say "listen_ip: $(yaml_get_first "$CONFIG_FILE" listen_ip)"
    say "src_ip:    $(yaml_get_first "$CONFIG_FILE" src_ip)"
    say "dst_ip:    $(yaml_get_first "$CONFIG_FILE" dst_ip)"
    say "protocol:  $(yaml_get_first "$CONFIG_FILE" protocol)"
  else
    err "Config not found."
  fi
  pause
}

action_uninstall() {
  require_root
  echo
  warn "This will remove service + installed files:"
  echo "  - $SERVICE_FILE"
  echo "  - $INSTALL_DIR"
  echo "  - $REPO_DIR"
  echo
  read -rp "Continue? (y/N): " ans </dev/tty || true
  case "${ans:-N}" in
    y|Y) ;;
    *) ok "Cancelled."; return ;;
  esac

  systemctl stop "$SERVICE_NAME" || true
  systemctl disable "$SERVICE_NAME" || true
  rm -f "$SERVICE_FILE" || true
  systemctl daemon-reload || true
  systemctl reset-failed || true

  rm -rf "$INSTALL_DIR" "$REPO_DIR" || true
  ok "Uninstall complete."
  pause
}

# -------------------------
# Menu
# -------------------------
menu() {
  while true; do
    clear || true
    echo "========================================"
    echo "              Bifrost Manager"
    echo "========================================"
    echo "Repo:    $REPO ($BRANCH)"
    echo "Status:  $(service_status_short)"
    echo "Version: $(current_version)"
    echo "$HR"
    echo "1) Install / Update (full)"
    echo "2) Configure only (no reinstall)"
    echo "3) Edit full config in nano"
    echo "4) Start"
    echo "5) Stop"
    echo "6) Restart"
    echo "7) Show status"
    echo "8) Show logs"
    echo "9) Show config summary"
    echo "10) Uninstall"
    echo "0) Exit"
    echo "$HR"
    read -rp "Choose: " choice </dev/tty || true
    case "$choice" in
      1) action_install_update ;;
      2) action_config_only ;;
      3) edit_config_nano ;;
      4) action_start ;;
      5) action_stop ;;
      6) action_restart ;;
      7) action_status ;;
      8) action_logs ;;
      9) action_show_config_summary ;;
      10) action_uninstall ;;
      0) exit 0 ;;
      *) warn "Invalid option"; pause ;;
    esac
  done
}

menu