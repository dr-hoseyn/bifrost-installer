#!/usr/bin/env bash
set -euo pipefail

REPO="dr-hoseyn/bifrost-installer"
BRANCH="main"
DIR="/opt/bifrost-installer"

if ! command -v git >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y git
fi

if [ -d "$DIR/.git" ]; then
  sudo git -C "$DIR" fetch --all
  sudo git -C "$DIR" reset --hard "origin/$BRANCH"
else
  sudo rm -rf "$DIR"
  sudo git clone --branch "$BRANCH" "https://github.com/$REPO.git" "$DIR"
fi

cd "$DIR"
sudo bash manager.sh