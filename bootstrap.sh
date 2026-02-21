#!/usr/bin/env bash
set -euo pipefail

REPO="dr-hoseyn/bifrost-installer"
BRANCH="main"
APP_DIR="/opt/bifrost-installer"

if ! command -v git >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y git
fi

if [ -d "$APP_DIR/.git" ]; then
  sudo git -C "$APP_DIR" fetch --all
  sudo git -C "$APP_DIR" reset --hard "origin/$BRANCH"
else
  sudo rm -rf "$APP_DIR"
  sudo git clone --branch "$BRANCH" "https://github.com/$REPO.git" "$APP_DIR"
fi

cd "$APP_DIR"
sudo bash install.sh