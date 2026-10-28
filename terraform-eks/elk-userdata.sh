#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io docker-compose-v2
systemctl enable --now docker
echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-elasticsearch.conf
sysctl --system
mkdir -p /opt/elk
echo '${compose_b64}' | base64 -d > /opt/elk/docker-compose.yml
cd /opt/elk
docker compose up -d
