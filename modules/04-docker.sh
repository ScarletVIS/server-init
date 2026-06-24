#!/usr/bin/env bash
#
# 04-docker.sh — установка Docker из официального репозитория, добавление юзера
# в группу docker. Запуск отдельно:  sudo ./modules/04-docker.sh
#
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"
load_state
require_root

hdr "Docker"
confirm "Установить Docker (официальный репозиторий)?" y || { say "Пропуск."; exit 0; }
ensure_user

# ─── выполнение ──────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
apt-get update -y || true
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$NEWUSER"
ok "Docker установлен, $NEWUSER добавлен в группу docker"
docker run --rm hello-world >/dev/null 2>&1 && ok "hello-world прошёл" || warn "проверь docker вручную"
docker compose version || true
warn "Чтобы группа docker применилась — перелогинься под $NEWUSER."
