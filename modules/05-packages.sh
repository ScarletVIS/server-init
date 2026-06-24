#!/usr/bin/env bash
#
# 05-packages.sh — установка произвольных пакетов через apt.
# Запуск отдельно:  sudo ./modules/05-packages.sh
#   (можно сразу аргументами:  sudo ./modules/05-packages.sh make git htop)
#
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"
load_state
require_root

hdr "Утилиты"
EXTRA_PKGS="$*"
if [[ -z "$EXTRA_PKGS" ]]; then
  if confirm "Установить дополнительные пакеты через apt?" n; then
    say "Впиши пакеты через пробел (например: make git htop curl wget)."
    read -rp "Пакеты: " EXTRA_PKGS || true
  fi
fi
EXTRA_PKGS="$(printf '%s' "$EXTRA_PKGS" | tr -s ' ' | sed 's/^ *//; s/ *$//')"
[[ -z "$EXTRA_PKGS" ]] && { warn "ничего не указано — пропуск."; exit 0; }

# ─── выполнение ──────────────────────────────────────────────────────────────
ok "к установке: $EXTRA_PKGS"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || true
# shellcheck disable=SC2086
if apt-get install -y $EXTRA_PKGS; then
  ok "пакеты установлены: $EXTRA_PKGS"
else
  warn "часть пакетов не установилась — проверь имена: $EXTRA_PKGS"
fi
