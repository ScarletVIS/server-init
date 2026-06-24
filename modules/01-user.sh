#!/usr/bin/env bash
#
# 01-user.sh — создание/настройка пользователя: sudo, пароль, публичные ключи.
# Запуск отдельно:  sudo ./modules/01-user.sh
#
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"
load_state
require_root

hdr "Пользователь"
ensure_user
ensure_access

USER_EXISTS=0
if id "$NEWUSER" &>/dev/null; then
  USER_EXISTS=1
  warn "Пользователь '$NEWUSER' уже существует."
  confirm "Донастроить существующего (sudo/ключи/пароль)?" y || { err "Прервано."; exit 1; }
fi

ADD_SUDO=0
confirm "Добавить в группу sudo?" y && ADD_SUDO=1

# пароль
PASSWORD=""
if [[ $WANT_PASSWORD -eq 1 ]]; then
  while :; do
    read -rsp "Пароль: " p1 || true; echo
    read -rsp "Повтор: " p2 || true; echo
    [[ -z "$p1" ]]        && { warn "Пустой пароль не годится."; continue; }
    [[ "$p1" != "$p2" ]]  && { warn "Не совпадает, ещё раз."; continue; }
    PASSWORD="$p1"; break
  done
fi

# ключи — минимум один, если выбран доступ по ключу
declare -a KEYS=()
if [[ $WANT_KEY -eq 1 ]]; then
  say ""
  say "Вставляй публичные ключи (ssh-ed25519 ... / ssh-rsa ...), по одному в строке."
  say "Пустая строка — закончить ввод."
  while :; do
    read -rp "Ключ: " k || true
    if [[ -z "$k" ]]; then
      [[ ${#KEYS[@]} -eq 0 ]] && { warn "Нужен хотя бы один ключ."; continue; }
      break
    fi
    if valid_key "$k"; then
      KEYS+=("$k"); ok "принят (${#KEYS[@]})"
    else
      warn "Не похоже на публичный ключ — пропущен."
    fi
  done
fi

# ─── выполнение ──────────────────────────────────────────────────────────────
hdr "Создание/настройка пользователя"
if [[ $USER_EXISTS -eq 0 ]]; then
  adduser --disabled-password --gecos "" "$NEWUSER"
  ok "пользователь создан"
fi
if [[ $WANT_PASSWORD -eq 1 ]]; then
  echo "${NEWUSER}:${PASSWORD}" | chpasswd
  ok "пароль установлен"
fi
if [[ $ADD_SUDO -eq 1 ]]; then
  usermod -aG sudo "$NEWUSER"
  ok "добавлен в sudo"
fi
if [[ ${#KEYS[@]} -gt 0 ]]; then
  HOME_DIR="$(getent passwd "$NEWUSER" | cut -d: -f6)"
  install -d -m 700 -o "$NEWUSER" -g "$NEWUSER" "$HOME_DIR/.ssh"
  AUTH="$HOME_DIR/.ssh/authorized_keys"
  touch "$AUTH"
  for k in "${KEYS[@]}"; do
    grep -qxF "$k" "$AUTH" || printf '%s\n' "$k" >> "$AUTH"
  done
  chmod 600 "$AUTH"
  chown "$NEWUSER:$NEWUSER" "$AUTH"
  ok "ключей в authorized_keys: $(wc -l < "$AUTH")"
fi
