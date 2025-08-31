#!/usr/bin/env bash
set -euo pipefail
sed -i 's/\r$//' /var/app/current/config/fluentd.conf || true
cp -f /var/app/current/config/fluentd.conf /etc/fluent/fluent.conf || true
systemctl restart fluentd || systemctl start fluentd