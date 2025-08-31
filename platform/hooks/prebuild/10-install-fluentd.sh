#!/usr/bin/env bash
set -euo pipefail

# (선택) CRLF 방지
for f in /var/app/staging/.platform/hooks/prebuild/*.sh /var/app/staging/.platform/hooks/postdeploy/*.sh; do
  [[ -f "$f" ]] && sed -i 's/\r$//' "$f"
done

# dnf install -y ruby ruby-devel  #Only if you need it

dnf install -y gcc make || true

# Edit if you need any additional plugins
gem update --system --no-document || true
gem install --no-document fluentd
gem install --no-document fluent-plugin-kinesis fluent-plugin-rewrite-tag-filter fluent-plugin-record-modifier

# 설치된 fluentd 실행 경로 찾기
FLUENTD_BIN="$(ruby -e 'puts Gem.bindir')/fluentd"
[[ -x "$FLUENTD_BIN" ]] || FLUENTD_BIN="$(command -v fluentd)"

install -d -m 755 /etc/fluent /etc/fluent/plugin /var/log/fluent/buffer/kinesis
cp -f /var/app/staging/config/fluentd.conf /etc/fluent/fluent.conf

# systemd 유닛
cat >/etc/systemd/system/fluentd.service <<UNIT
[Unit]
Description=Fluentd log collector
After=network.target
[Service]
Type=simple
ExecStart=${FLUENTD_BIN} -c /etc/fluent/fluent.conf -qq -o /var/log/fluent/fluentd.log -p /etc/fluent/plugin
Restart=always
RestartSec=5
User=root
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable fluentd
