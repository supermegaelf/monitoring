#!/bin/bash

read -p "Grafana, Prometheus and Node Exporter domain: " DOMAIN

SERVER_IP=$(hostname -I | awk '{print $1}')

cat <<EOF > /etc/nginx/conf.d/grafana.conf
server {
    listen 8444 ssl;
    server_name grafana.$DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    include /etc/nginx/snippets/ssl.conf;
    include /etc/nginx/snippets/ssl-params.conf;
}
EOF

cat <<EOF > /etc/nginx/conf.d/prometheus.conf
server {
    server_name prometheus.$DOMAIN;

    listen 8444 ssl;
    http2 on;

    location / {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    include /etc/nginx/snippets/ssl.conf;
    include /etc/nginx/snippets/ssl-params.conf;
}
EOF

cat <<EOF > /etc/nginx/conf.d/node-exporter.conf
server {
    server_name node-exporter.$DOMAIN;

    listen 8444 ssl;
    http2 on;

    location / {
        proxy_pass http://127.0.0.1:9100;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    include /etc/nginx/snippets/ssl.conf;
    include /etc/nginx/snippets/ssl-params.conf;
}
EOF

echo "Checking Nginx configuration..."
nginx -t && systemctl restart nginx

mkdir -p /opt/monitoring/prometheus

cat <<EOF > /opt/monitoring/docker-compose.yml
services:
  grafana:
    image: grafana/grafana
    container_name: grafana
    restart: unless-stopped
    ports:
     - 127.0.0.1:3000:3000
    volumes:
      - grafana-storage:/var/lib/grafana

  prometheus:
    image: prom/prometheus
    container_name: prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
    ports:
      - 127.0.0.1:9090:9090
    restart: unless-stopped
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - prom_data:/prometheus

volumes:
  grafana-storage:
    external: true
  prom_data:
    external: true
EOF

cat <<EOF > /opt/monitoring/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s
alerting:
  alertmanagers:
    - static_configs:
      - targets: []
      scheme: http
      timeout: 10s
      api_version: v2
scrape_configs:
  - job_name: prometheus
    honor_timestamps: true
    scrape_interval: 15s
    scrape_timeout: 10s
    metrics_path: /metrics
    scheme: http
    static_configs:
      - targets:
        - localhost:9090
  - job_name: base
    static_configs:
      - targets: ['$SERVER_IP:9100']
EOF

docker volume create grafana-storage
docker volume create prom_data

cd /opt/monitoring/
wget -q https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar xvf node_exporter-1.8.2.linux-amd64.tar.gz
sudo cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin
rm -rf node_exporter-1.8.2.linux-amd64 node_exporter-1.8.2.linux-amd64.tar.gz

sudo useradd --no-create-home --shell /bin/false node_exporter
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

cat <<EOF > /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

ufw allow from $SERVER_IP to any port 9100 proto tcp comment "Node Exporter"
ufw allow from 172.17.0.0/16 to any port 9100 proto tcp comment "Node Exporter Docker Network 1"
ufw allow from 172.18.0.0/16 to any port 9100 proto tcp comment "Node Exporter Docker Network 2"

ufw reload

sudo systemctl daemon-reload
sudo systemctl enable node_exporter
sudo systemctl start node_exporter

docker compose -f /opt/monitoring/docker-compose.yml up -d

echo "Done."
echo "Prometheus: https://prometheus.$DOMAIN"
echo "Grafana: https://grafana.$DOMAIN"
