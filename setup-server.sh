#!/usr/bin/env bash
#
# setup-server.sh — первоначальная настройка свежего Ubuntu (22.04/24.04).
# Создание пользователя, доступ (пароль / ключ / оба), харденинг SSH,
# fail2ban и опционально Docker.
#
# Запуск:  sudo bash setup-server.sh
#
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

# ─── проверки ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Запусти от root:  sudo bash $0"
  exit 1
fi
. /etc/os-release 2>/dev/null || true
say "ОС: ${PRETTY_NAME:-неизвестно}"

# ─── helpers ─────────────────────────────────────────────────────────────────
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

# ═════════════════════════════════════════════════════════════════════════════
#  1. СБОР ПАРАМЕТРОВ (ничего не меняем, только спрашиваем)
# ═════════════════════════════════════════════════════════════════════════════
hdr "Пользователь"

while :; do
  read -rp "Имя пользователя: " NEWUSER || true
  if [[ ! "$NEWUSER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    warn "Имя должно начинаться с буквы/_ и содержать [a-z0-9_-]."
    continue
  fi
  break
done

USER_EXISTS=0
if id "$NEWUSER" &>/dev/null; then
  USER_EXISTS=1
  warn "Пользователь '$NEWUSER' уже существует."
  confirm "Донастроить существующего (sudo/ключи/пароль)?" y || { err "Прервано."; exit 1; }
fi

ADD_SUDO=0
confirm "Добавить в группу sudo?" y && ADD_SUDO=1

# тип доступа
say ""
say "Тип доступа по SSH:"
say "  1) только пароль"
say "  2) только ключ"
say "  3) пароль и ключ одновременно"
ACCESS=""
while :; do
  read -rp "Выбор [1-3]: " ACCESS || true
  [[ "$ACCESS" =~ ^[123]$ ]] && break
  warn "Введи 1, 2 или 3."
done
WANT_PASSWORD=0; WANT_KEY=0
case "$ACCESS" in
  1) WANT_PASSWORD=1 ;;
  2) WANT_KEY=1 ;;
  3) WANT_PASSWORD=1; WANT_KEY=1 ;;
esac

# пароль
PASSWORD=""
if [[ $WANT_PASSWORD -eq 1 ]]; then
  while :; do
    read -rsp "Пароль: " p1 || true; echo
    read -rsp "Повтор: " p2 || true; echo
    if [[ -z "$p1" ]]; then warn "Пустой пароль не годится."; continue; fi
    if [[ "$p1" != "$p2" ]]; then warn "Не совпадает, ещё раз."; continue; fi
    PASSWORD="$p1"; break
  done
fi

# ключи — требуем минимум один, если выбран доступ по ключу
declare -a KEYS=()
if [[ $WANT_KEY -eq 1 ]]; then
  say ""
  say "Вставляй публичные ключи (ssh-ed25519 ... / ssh-rsa ...), по одному в строке."
  say "Пустая строка — закончить ввод."
  while :; do
    read -rp "Ключ: " k || true
    if [[ -z "$k" ]]; then
      if [[ ${#KEYS[@]} -eq 0 ]]; then
        warn "Доступ по ключу выбран, но ни одного ключа нет. Нужен хотя бы один."
        continue
      fi
      break
    fi
    if valid_key "$k"; then
      KEYS+=("$k"); ok "принят (${#KEYS[@]})"
    else
      warn "Не похоже на публичный ключ — пропущен."
    fi
  done
fi

# ─── харденинг SSH ───────────────────────────────────────────────────────────
hdr "SSH"

DISABLE_ROOT=0
confirm "Запретить вход под root по SSH?" y && DISABLE_ROOT=1

# Парольную аутентификацию можно выключить только если пароль доступа не нужен.
DISABLE_PWAUTH=0
if [[ $WANT_PASSWORD -eq 1 ]]; then
  warn "Доступ по паролю выбран → PasswordAuthentication остаётся yes."
else
  if confirm "Отключить парольную аутентификацию SSH (только ключи)?" y; then
    DISABLE_PWAUTH=1
  fi
fi

read -rp "Порт SSH [22]: " SSH_PORT || true
SSH_PORT="${SSH_PORT:-22}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || { warn "Порт нечисловой, ставлю 22."; SSH_PORT=22; }

# ─── fail2ban ────────────────────────────────────────────────────────────────
hdr "fail2ban"
INSTALL_F2B=0; CONFIG_F2B=0
F2B_BANTIME="1h"; F2B_FINDTIME="10m"; F2B_MAXRETRY="5"
if confirm "Установить fail2ban?" y; then
  INSTALL_F2B=1
  if confirm "Настроить jail для sshd?" y; then
    CONFIG_F2B=1
    read -rp "  bantime  [1h]:  " x || true; F2B_BANTIME="${x:-1h}"
    read -rp "  findtime [10m]: " x || true; F2B_FINDTIME="${x:-10m}"
    read -rp "  maxretry [5]:   " x || true; F2B_MAXRETRY="${x:-5}"
  fi
fi

# ─── Docker ──────────────────────────────────────────────────────────────────
hdr "Docker"
INSTALL_DOCKER=0
confirm "Установить Docker (официальный репозиторий)?" y && INSTALL_DOCKER=1

# ═════════════════════════════════════════════════════════════════════════════
#  СВОДКА И ПОДТВЕРЖДЕНИЕ
# ═════════════════════════════════════════════════════════════════════════════
hdr "Что будет сделано"
say "  Пользователь:        $NEWUSER $( ((USER_EXISTS)) && echo '(существует)' )"
say "  sudo:                $( ((ADD_SUDO)) && echo да || echo нет )"
say "  Доступ:              $( ((WANT_PASSWORD)) && printf 'пароль ' )$( ((WANT_KEY)) && printf 'ключ' )"
say "  Ключей добавить:     ${#KEYS[@]}"
say "  Root по SSH:         $( ((DISABLE_ROOT)) && echo запрещён || echo без изменений )"
say "  PasswordAuth:        $( ((DISABLE_PWAUTH)) && echo no || echo yes )"
say "  Порт SSH:            $SSH_PORT"
say "  fail2ban:            $( ((INSTALL_F2B)) && echo "установить$( ((CONFIG_F2B)) && echo " + jail (ban $F2B_BANTIME / try $F2B_MAXRETRY)" )" || echo нет )"
say "  Docker:              $( ((INSTALL_DOCKER)) && echo установить || echo нет )"
say ""
confirm "Применить?" y || { err "Отмена."; exit 1; }

# ═════════════════════════════════════════════════════════════════════════════
#  2. ВЫПОЛНЕНИЕ
# ═════════════════════════════════════════════════════════════════════════════

# ─── пользователь ────────────────────────────────────────────────────────────
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

# ─── ключи ───────────────────────────────────────────────────────────────────
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

# ─── харденинг SSH ───────────────────────────────────────────────────────────
hdr "Настройка sshd"
# Подвох Ubuntu 24.04 / облачных образов: include'ы из sshd_config.d/*.conf
# читаются ПЕРВЫМИ, а sshd берёт первое найденное значение → 50-cloud-init.conf
# с "PasswordAuthentication yes" перебивает основной конфиг.
# Решение: (1) наш drop-in с префиксом 00- читается раньше всех и выигрывает,
# (2) на всякий случай гасим конфликтующие директивы в остальных drop-in'ах.
DROPDIR=/etc/ssh/sshd_config.d
OURFILE="$DROPDIR/00-hardening-grill.conf"
install -d -m 755 "$DROPDIR"

# гасим конфликты в чужих drop-in'ах (с бэкапом)
shopt -s nullglob
for f in "$DROPDIR"/*.conf; do
  [[ "$f" == "$OURFILE" ]] && continue
  if grep -qiE '^\s*(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)\b' "$f"; then
    cp -a "$f" "$f.bak.$(date +%s)"
    sed -ri 's/^(\s*)(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)\b/\1# [grill] \2/I' "$f"
    warn "поправлен $f (бэкап рядом)"
  fi
done
shopt -u nullglob

# вычисляем значения
PRL=$( ((DISABLE_ROOT)) && echo no || echo prohibit-password )
PWA=$( ((DISABLE_PWAUTH)) && echo no || echo yes )

cat > "$OURFILE" <<EOF
# Создано setup-server.sh $(date -Is)
# Этот файл читается раньше остальных (префикс 00-) и имеет приоритет.
PermitRootLogin $PRL
PasswordAuthentication $PWA
PubkeyAuthentication yes
EOF
[[ "$SSH_PORT" != "22" ]] && echo "Port $SSH_PORT" >> "$OURFILE"
chmod 644 "$OURFILE"
ok "записан $OURFILE"

if sshd -t; then
  ok "sshd -t: синтаксис ок"
  if [[ $DISABLE_PWAUTH -eq 1 ]]; then
    warn "Парольный вход будет отключён. НЕ закрывай текущую сессию —"
    warn "открой НОВЫЙ терминал и проверь вход по ключу до перезапуска."
  fi
  if confirm "Перезапустить ssh сейчас?" y; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
    ok "ssh перезапущен"
  else
    warn "Перезапусти вручную: systemctl restart ssh"
  fi
else
  err "sshd -t показал ошибку — конфиг НЕ применён, ssh не трогаю."
fi

# ─── fail2ban ────────────────────────────────────────────────────────────────
if [[ $INSTALL_F2B -eq 1 ]]; then
  hdr "fail2ban"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
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
    ok "jail.local записан"
  fi
  systemctl enable --now fail2ban
  ok "fail2ban запущен"
  fail2ban-client status sshd 2>/dev/null || true
fi

# ─── Docker ──────────────────────────────────────────────────────────────────
if [[ $INSTALL_DOCKER -eq 1 ]]; then
  hdr "Docker"
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
  apt-get update -y
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
fi

hdr "Готово"
ok "Сервер настроен."
[[ ${#KEYS[@]} -gt 0 ]] && say "Проверка входа:  ssh -p $SSH_PORT $NEWUSER@<IP>"