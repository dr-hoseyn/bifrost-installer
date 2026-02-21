#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Repo settings
# -------------------------
REPO="dr-hoseyn/bifrost-installer"
BRANCH="main"
REPO_DIR="/opt/bifrost-installer"

# -------------------------
# Install paths
# -------------------------
INSTALL_DIR="/opt/bifrost"
SERVICE_NAME="bifrost"
APP_USER="bifrost"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Config location inside installed files
CONFIG_DIR="${INSTALL_DIR}/configs"
CONFIG_FILE_NAME="config.yaml"   # <-- change if needed
CONFIG_FILE="${CONFIG_DIR}/${CONFIG_FILE_NAME}"

# -------------------------
# Helpers
# -------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root:"
    echo "  sudo bash manager.sh"
    exit 1
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

pause() {
  echo
  read -rp "Press Enter to continue..." _ </dev/tty || true
}

service_status_short() {
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "running"
  else
    echo "stopped"
  fi
}

current_version() {
  if [ -x "${INSTALL_DIR}/bifrost" ]; then
    if "${INSTALL_DIR}/bifrost" --version >/dev/null 2>&1; then
      "${INSTALL_DIR}/bifrost" --version 2>/dev/null | head -n 1
      return
    fi
    if "${INSTALL_DIR}/bifrost" -v >/dev/null 2>&1; then
      "${INSTALL_DIR}/bifrost" -v 2>/dev/null | head -n 1
      return
    fi
    echo "Installed (version unknown)"
  else
    echo "Not installed"
  fi
}

ensure_deps() {
  if ! need_cmd git; then
    apt-get update -y
    apt-get install -y git
  fi

  # for auto public ip (tries curl/wget/dig)
  if ! need_cmd curl && ! need_cmd wget; then
    apt-get update -y
    apt-get install -y curl
  fi

  # python3 optional (safer editing); sed fallback exists
  true
}

sync_repo() {
  ensure_deps
  if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" fetch --all --prune
    git -C "$REPO_DIR" reset --hard "origin/$BRANCH"
  else
    rm -rf "$REPO_DIR"
    git clone --branch "$BRANCH" "https://github.com/$REPO.git" "$REPO_DIR"
  fi
}

ensure_user() {
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"
  fi
}

# Try to discover server public IPv4
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
  if [ -z "$ip" ] && need_cmd dig; then
    ip="$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | tail -n 1 || true)"
  fi
  # last resort: outward interface IP (might be private)
  if [ -z "$ip" ] && need_cmd ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 || true)"
  fi
  echo "$ip"
}

# Read current values from config (best effort)
read_config_value() {
  local key="$1"
  local file="$2"
  if [ ! -f "$file" ]; then
    echo ""
    return
  fi
  grep -E "^[[:space:]]*${key}:" "$file" | head -n 1 | sed -E 's/^[[:space:]]*[^:]+:[[:space:]]*//; s/"//g; s/[[:space:]]+$//'
}

# Update YAML keys (listen_ip/src_ip/dst_ip).
update_config_keys() {
  local file="$1"
  local listen_ip="$2"
  local src_ip="$3"
  local dst_ip="$4"

  if [ ! -f "$file" ]; then
    echo "ERROR: Config file not found: $file"
    return 1
  fi

  if need_cmd python3; then
    python3 - "$file" "$listen_ip" "$src_ip" "$dst_ip" <<'PY'
import re, sys
path, listen_ip, src_ip, dst_ip = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
txt = open(path, "r", encoding="utf-8", errors="ignore").read()

def repl_first(pattern, replacement, text):
    m = re.search(pattern, text, flags=re.M)
    if not m:
        return text, False
    return re.sub(pattern, replacement, text, count=1, flags=re.M), True

txt, _ = repl_first(r'^(\s*listen_ip:\s*)(".*?"|\S+)\s*$', rf'\1"{listen_ip}"', txt)
txt, _ = repl_first(r'^(\s*src_ip:\s*)(".*?"|\S+)\s*$',    rf'\1"{src_ip}"',    txt)
txt, _ = repl_first(r'^(\s*dst_ip:\s*)(".*?"|\S+)\s*$',    rf'\1"{dst_ip}"',    txt)

open(path, "w", encoding="utf-8").write(txt)
PY
  else
    sed -i -E "s/^([[:space:]]*listen_ip:)[[:space:]]*(\"[^\"]*\"|[^[:space:]]+)[[:space:]]*$/\1 \"${listen_ip}\"/" "$file" || true
    sed -i -E "s/^([[:space:]]*src_ip:)[[:space:]]*(\"[^\"]*\"|[^[:space:]]+)[[:space:]]*$/\1 \"${src_ip}\"/" "$file" || true
    sed -i -E "s/^([[:space:]]*dst_ip:)[[:space:]]*(\"[^\"]*\"|[^[:space:]]+)[[:space:]]*$/\1 \"${dst_ip}\"/" "$file" || true
  fi
}

# NEW BEHAVIOR:
# - listen_ip default = auto server IP (always)
# - src_ip    default = auto server IP (always)
# - show current config values too
# - Enter => auto IP (even if config currently has something else)
# - dst_ip: show current and Enter keeps current; if missing, require input
configure_interactive() {
  mkdir -p "$CONFIG_DIR"

  local auto_ip
  auto_ip="$(get_public_ip)"
  if [ -z "$auto_ip" ]; then
    echo "WARNING: Could not detect server public IP automatically."
    echo "You must enter listen_ip and src_ip manually."
  fi

  local current_listen current_src current_dst
  current_listen="$(read_config_value "listen_ip" "$CONFIG_FILE")"
  current_src="$(read_config_value "src_ip" "$CONFIG_FILE")"
  current_dst="$(read_config_value "dst_ip" "$CONFIG_FILE")"

  echo
  echo "Configuration will be written to:"
  echo "  $CONFIG_FILE"
  echo

  # listen_ip
  while true; do
    if [ -n "$auto_ip" ]; then
      if [ -n "$current_listen" ]; then
        read -rp "listen_ip [auto: ${auto_ip}] (current: ${current_listen}) (Enter = auto): " in_listen </dev/tty || true
      else
        read -rp "listen_ip [auto: ${auto_ip}] (Enter = auto): " in_listen </dev/tty || true
      fi
      listen_ip="${in_listen:-$auto_ip}"
    else
      read -rp "listen_ip (required): " listen_ip </dev/tty
    fi
    [ -n "${listen_ip:-}" ] && break
    echo "listen_ip cannot be empty."
  done

  # src_ip
  while true; do
    if [ -n "$auto_ip" ]; then
      if [ -n "$current_src" ]; then
        read -rp "src_ip [auto: ${auto_ip}] (current: ${current_src}) (Enter = auto): " in_src </dev/tty || true
      else
        read -rp "src_ip [auto: ${auto_ip}] (Enter = auto): " in_src </dev/tty || true
      fi
      src_ip="${in_src:-$auto_ip}"
    else
      read -rp "src_ip (required): " src_ip </dev/tty
    fi
    [ -n "${src_ip:-}" ] && break
    echo "src_ip cannot be empty."
  done

  # dst_ip (required; default = current if present)
  if [ -n "$current_dst" ]; then
    read -rp "dst_ip (current: ${current_dst}) (Enter = keep current): " in_dst </dev/tty || true
    dst_ip="${in_dst:-$current_dst}"
  else
    while true; do
      read -rp "dst_ip (required): " dst_ip </dev/tty
      [ -n "$dst_ip" ] && break
      echo "dst_ip cannot be empty."
    done
  fi

  echo
  echo "Applying:"
  echo "  listen_ip = $listen_ip"
  echo "  src_ip    = $src_ip"
  echo "  dst_ip    = $dst_ip"
  echo

  update_config_keys "$CONFIG_FILE" "$listen_ip" "$src_ip" "$dst_ip"
}

install_systemd_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Bifrost Service
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/bifrost ${CONFIG_FILE}
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
}

install_or_update() {
  require_root
  echo "Syncing repository..."
  sync_repo

  echo "Ensuring system user..."
  ensure_user

  echo "Installing files..."
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$REPO_DIR/bifrost" "${INSTALL_DIR}/bifrost"

  rm -rf "${INSTALL_DIR}/configs"
  if [ -d "$REPO_DIR/configs" ]; then
    cp -R "$REPO_DIR/configs" "${INSTALL_DIR}/configs"
  else
    mkdir -p "${INSTALL_DIR}/configs"
  fi

  chown -R "${APP_USER}:${APP_USER}" "$INSTALL_DIR"

  echo "Configuring (listen_ip, src_ip, dst_ip)..."
  configure_interactive

  echo "Installing systemd service..."
  install_systemd_service

  echo
  echo "Done. Service status:"
  systemctl --no-pager status "$SERVICE_NAME" || true
}

start_service() { require_root; systemctl start "$SERVICE_NAME"; }
stop_service() { require_root; systemctl stop "$SERVICE_NAME"; }
restart_service(){ require_root; systemctl restart "$SERVICE_NAME"; }

show_logs() {
  echo "Press Ctrl+C to exit logs."
  journalctl -u "$SERVICE_NAME" -f
}

show_config_summary() {
  echo
  echo "Installed config file:"
  echo "  $CONFIG_FILE"
  if [ -f "$CONFIG_FILE" ]; then
    echo
    echo "Current values:"
    echo "  listen_ip: $(read_config_value "listen_ip" "$CONFIG_FILE")"
    echo "  src_ip:    $(read_config_value "src_ip" "$CONFIG_FILE")"
    echo "  dst_ip:    $(read_config_value "dst_ip" "$CONFIG_FILE")"
  else
    echo "Config file not found."
  fi
  pause
}

uninstall_all() {
  require_root
  echo "This will remove the service and all installed files:"
  echo "  - $SERVICE_FILE"
  echo "  - $INSTALL_DIR"
  echo "  - $REPO_DIR"
  echo
  read -rp "Continue? (y/N): " ans </dev/tty || true
  case "${ans:-N}" in
    y|Y) ;;
    *) echo "Cancelled."; return;;
  esac

  systemctl stop "$SERVICE_NAME" || true
  systemctl disable "$SERVICE_NAME" || true
  rm -f "$SERVICE_FILE" || true
  systemctl daemon-reload || true
  systemctl reset-failed || true

  rm -rf "$INSTALL_DIR" "$REPO_DIR" || true

  read -rp "Remove system user '${APP_USER}'? (y/N): " rmuser </dev/tty || true
  case "${rmuser:-N}" in
    y|Y) id -u "$APP_USER" >/dev/null 2>&1 && userdel "$APP_USER" || true ;;
  esac

  echo "Uninstall complete."
}

menu() {
  while true; do
    clear || true
    echo "================================"
    echo "          Bifrost Manager"
    echo "================================"
    echo "Repo:    $REPO ($BRANCH)"
    echo "Status:  $(service_status_short)"
    echo "Version: $(current_version)"
    echo "--------------------------------"
    echo "1) Install / Update"
    echo "2) Start"
    echo "3) Stop"
    echo "4) Restart"
    echo "5) Show Status"
    echo "6) Show Logs"
    echo "7) Show Config Summary"
    echo "8) Uninstall"
    echo "0) Exit"
    echo "--------------------------------"
    read -rp "Choose: " choice </dev/tty || true
    case "$choice" in
      1) install_or_update; pause;;
      2) start_service; pause;;
      3) stop_service; pause;;
      4) restart_service; pause;;
      5) systemctl --no-pager status "$SERVICE_NAME" || true; pause;;
      6) show_logs;;
      7) show_config_summary;;
      8) uninstall_all; pause;;
      0) exit 0;;
      *) echo "Invalid option"; pause;;
    esac
  done
}

menu