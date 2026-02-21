#!/usr/bin/env bash
set -euo pipefail

REPO="dr-hoseyn/bifrost-installer"
BRANCH="main"

INSTALL_DIR="/opt/bifrost"
ENV_DIR="/etc/bifrost"
ENV_FILE="${ENV_DIR}/bifrost.env"
SERVICE_FILE="/etc/systemd/system/bifrost.service"
SERVICE_NAME="bifrost"
APP_USER="bifrost"
REPO_DIR="/opt/bifrost-installer"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root:"
    echo "  sudo bash manager.sh"
    exit 1
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

pause() {
  echo
  read -rp "Press Enter to continue..."
}

ensure_deps() {
  if ! need_cmd git; then
    apt-get update -y
    apt-get install -y git
  fi
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

service_status_short() {
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "running"
  else
    echo "stopped"
  fi
}

write_env_interactive() {
  mkdir -p "$ENV_DIR"

  local PORT="8080"
  if [ -f "$ENV_FILE" ]; then
    PORT="$(grep -E '^BIFROST_PORT=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- || echo 8080)"
    PORT="${PORT:-8080}"
  fi

  echo
  echo "Configuration:"
  read -rp "Port (default ${PORT}): " INP_PORT
  PORT="${INP_PORT:-$PORT}"

  cat > "$ENV_FILE" <<EOF
BIFROST_PORT=${PORT}
BIFROST_CONFIG_DIR=${INSTALL_DIR}/configs
EOF

  chmod 0640 "$ENV_FILE"
  chown root:"$APP_USER" "$ENV_FILE"
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

  echo "Writing environment file..."
  write_env_interactive

  echo "Installing systemd service..."
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Bifrost Service
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/bifrost
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"

  echo
  echo "Installation complete."
  systemctl --no-pager status "$SERVICE_NAME" || true
}

start_service() { require_root; systemctl start "$SERVICE_NAME"; }
stop_service() { require_root; systemctl stop "$SERVICE_NAME"; }
restart_service(){ require_root; systemctl restart "$SERVICE_NAME"; }

show_logs() {
  echo "Press Ctrl+C to exit logs."
  journalctl -u "$SERVICE_NAME" -f
}

uninstall_all() {
  require_root
  echo "This will remove the service and all installed files."
  read -rp "Continue? (y/N): " ans
  case "${ans:-N}" in
    y|Y) ;;
    *) echo "Cancelled."; return;;
  esac

  systemctl stop "$SERVICE_NAME" || true
  systemctl disable "$SERVICE_NAME" || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl reset-failed || true

  rm -rf "$INSTALL_DIR" "$ENV_DIR" "$REPO_DIR"

  read -rp "Remove system user '${APP_USER}'? (y/N): " rmuser
  case "${rmuser:-N}" in
    y|Y) id -u "$APP_USER" >/dev/null 2>&1 && userdel "$APP_USER" || true ;;
  esac

  echo "Uninstall complete."
}

menu() {
  while true; do
    clear || true
    echo "================================"
    echo "        Bifrost Manager"
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
    echo "7) Uninstall"
    echo "0) Exit"
    echo "--------------------------------"
    read -rp "Choose: " choice
    case "$choice" in
      1) install_or_update; pause;;
      2) start_service; pause;;
      3) stop_service; pause;;
      4) restart_service; pause;;
      5) systemctl --no-pager status "$SERVICE_NAME" || true; pause;;
      6) show_logs;;
      7) uninstall_all; pause;;
      0) exit 0;;
      *) echo "Invalid option"; pause;;
    esac
  done
}

menu