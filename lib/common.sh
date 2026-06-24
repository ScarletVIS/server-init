#!/usr/bin/env bash
#
# lib/common.sh — общие помощники для модулей setup-server.
# Подключается из модуля так:
#   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$HERE/../lib/common.sh"
#
# Межмодульное состояние (NEWUSER, ACCESS, SSH_PORT) передаётся через файл,
# путь к которому лежит в $SETUP_STATE (его выставляет оркестратор). При
# самостоятельном запуске модуля переменная пуста — модуль просто спросит сам.

set -euo pipefail

# ─── оформление ──────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  B=$'\e[1m'; R=$'\e[0m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RED=$'\e[31m'; CYN=$'\e[36m'
else
  B=''; R=''; GRN=''; YEL=''; RED=''; CYN=''
fi
say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$B$CYN" "$*" "$R"; }
ok()   { printf '%s[ok]%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s[!]%s  %s\n' "$YEL" "$R" "$*"; }
err()  { printf '%s[x]%s  %s\n' "$RED" "$R" "$*" >&2; }

# ─── проверки/валидаторы ─────────────────────────────────────────────────────
require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Запусти от root:  sudo $0"
    exit 1
  fi
}

confirm() {                       # confirm "Вопрос?" [y|n] -> код возврата
  local p="$1" d="${2:-y}" a hint="[Y/n]"
  [[ $d == n ]] && hint="[y/N]"
  read -rp "$p $hint " a || true
  a="${a:-$d}"
  [[ ${a,,} == y* ]]
}

valid_key() {                     # грубая проверка формата публичного ключа
  [[ "$1" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]]
}

valid_port()     { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; }

rand_port() {                     # случайный высокий порт
  if command -v shuf >/dev/null 2>&1; then
    shuf -i 20000-60000 -n1
  else
    echo $(( (RANDOM % 40001) + 20000 ))
  fi
}

# ─── межмодульное состояние ──────────────────────────────────────────────────
load_state() {                    # подтянуть сохранённые значения, если есть
  local f="${SETUP_STATE:-}"
  [[ -n "$f" && -f "$f" ]] && source "$f"
  return 0
}
save_state() {                    # save_state NAME VALUE — сохранить для других модулей
  local f="${SETUP_STATE:-}"
  export "$1=$2"
  [[ -z "$f" ]] && return 0
  printf '%s=%q\n' "$1" "$2" >> "$f"
}

# ─── общие интерактивные шаги ────────────────────────────────────────────────
ensure_user() {                   # NEWUSER из состояния/окружения или спросить
  if [[ -n "${NEWUSER:-}" ]] && valid_username "$NEWUSER"; then
    return
  fi
  while :; do
    read -rp "Имя пользователя: " NEWUSER || true
    valid_username "$NEWUSER" && break
    warn "Имя должно начинаться с буквы/_ и содержать [a-z0-9_-]."
  done
  save_state NEWUSER "$NEWUSER"
}

# ACCESS (1|2|3) → WANT_PASSWORD / WANT_KEY / REQUIRE_BOTH
ensure_access() {
  if [[ ! "${ACCESS:-}" =~ ^[123]$ ]]; then
    say "Тип доступа по SSH:"
    say "  1) только пароль"
    say "  2) только ключ"
    say "  3) пароль и ключ одновременно (требуются оба)"
    while :; do
      read -rp "Выбор [1-3]: " ACCESS || true
      [[ "$ACCESS" =~ ^[123]$ ]] && break
      warn "Введи 1, 2 или 3."
    done
    save_state ACCESS "$ACCESS"
  fi
  WANT_PASSWORD=0; WANT_KEY=0; REQUIRE_BOTH=0
  case "$ACCESS" in
    1) WANT_PASSWORD=1 ;;
    2) WANT_KEY=1 ;;
    3) WANT_PASSWORD=1; WANT_KEY=1; REQUIRE_BOTH=1 ;;
  esac
}
