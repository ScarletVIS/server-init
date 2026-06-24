#!/usr/bin/env bash
#
# 03-fail2ban.sh — установка fail2ban и jail для sshd.
# Порт берётся из состояния (от 02-ssh) либо спрашивается.
# Запуск отдельно:  sudo ./modules/03-fail2ban.sh
#
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"
load_state
require_root

hdr "fail2ban"
confirm "Установить fail2ban?" y || { say "Пропуск."; exit 0; }

CONFIG_F2B=0
F2B_BANTIME="1h"; F2B_FINDTIME="10m"; F2B_MAXRETRY="5"
if confirm "Настроить jail для sshd?" y; then
  CONFIG_F2B=1
  read -rp "  bantime  [1h]:  " x || true; F2B_BANTIME="${x:-1h}"
  read -rp "  findtime [10m]: " x || true; F2B_FINDTIME="${x:-10m}"
  read -rp "  maxretry [5]:   " x || true; F2B_MAXRETRY="${x:-5}"

  if [[ -n "${SSH_PORT:-}" ]] && valid_port "$SSH_PORT"; then
    ok "порт SSH для jail: $SSH_PORT"
  else
    read -rp "  порт SSH [22]:  " SSH_PORT || true
    SSH_PORT="${SSH_PORT:-22}"
    valid_port "$SSH_PORT" || { warn "порт невалиден, ставлю 22"; SSH_PORT=22; }
  fi
fi

# ─── выполнение ──────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || true
apt-get install -y fail2ban
if [[ $CONFIG_F2B -eq 1 ]]; then
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = $F2B_BANTIME
findtime = $F2B_FINDTIME
maxretry = $F2B_MAXRETRY
backend  = systemd

[sshd]
enabled = true
port    = $SSH_PORT
EOF
  ok "jail.local записан (порт $SSH_PORT)"
fi
systemctl enable --now fail2ban
ok "fail2ban запущен"
fail2ban-client status sshd 2>/dev/null || true
