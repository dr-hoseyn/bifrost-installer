#!/bin/bash

SERVICE_NAME="bifrost"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "🔧 Creating systemd service..."

cat <<EOF > $SERVICE_FILE
[Unit]
Description=Bifrost Service
After=network.target

[Service]
Type=simple
ExecStart=/root/bifrost /root/configs.yaml
WorkingDirectory=/root
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "🔄 Reloading systemd..."
systemctl daemon-reload

echo "✅ Enabling service..."
systemctl enable $SERVICE_NAME

echo "🚀 Starting service..."
systemctl start $SERVICE_NAME

echo "📊 Service status:"
systemctl status $SERVICE_NAME --no-pager