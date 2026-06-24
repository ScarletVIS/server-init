#!/usr/bin/env bash
#
# 02-ssh.sh — харденинг sshd: root-логин, парольная аутентификация,
# AuthenticationMethods (пароль И ключ), смена порта. Drop-in именуется по юзеру.
# Запуск отдельно:  sudo ./modules/02-ssh.sh
#
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"
load_state
require_root

hdr "SSH"
ensure_user
ensure_access

DISABLE_ROOT=0
confirm "Запретить вход под root по SSH?" y && DISABLE_ROOT=1

# Парольную аутентификацию можно выключить, только если пароль не нужен для входа.
DISABLE_PWAUTH=0
if [[ $WANT_PASSWORD -eq 1 ]]; then
  warn "Доступ по паролю выбран → PasswordAuthentication остаётся yes."
else
  confirm "Отключить парольную аутентификацию SSH (только ключи)?" y && DISABLE_PWAUTH=1
fi

# порт: из состояния, либо спросить (пусто = случайный, валидируем диапазон)
if [[ -n "${SSH_PORT:-}" ]] && valid_port "$SSH_PORT"; then
  ok "порт SSH из состояния: $SSH_PORT"
else
  while :; do
    read -rp "Порт SSH [пусто = случайный]: " SSH_PORT || true
    if [[ -z "$SSH_PORT" ]]; then
      SSH_PORT="$(rand_port)"; ok "выбран случайный порт: $SSH_PORT"; break
    fi
    valid_port "$SSH_PORT" && break
    warn "Порт должен быть числом в диапазоне 1..65535."
  done
fi
save_state SSH_PORT "$SSH_PORT"

# ─── выполнение ──────────────────────────────────────────────────────────────
hdr "Настройка sshd"
# Подвох облачных образов: drop-in'ы из sshd_config.d/*.conf читаются ПЕРВЫМИ,
# sshd берёт первое найденное значение → 50-cloud-init.conf с
# "PasswordAuthentication yes" перебивает основной конфиг.
# Решение: наш drop-in с префиксом 00- выигрывает + гасим конфликты в чужих.
DROPDIR=/etc/ssh/sshd_config.d
OURFILE="$DROPDIR/00-hardening-${NEWUSER}.conf"
install -d -m 755 "$DROPDIR"

shopt -s nullglob
for f in "$DROPDIR"/*.conf; do
  [[ "$f" == "$OURFILE" ]] && continue
  if grep -qiE '^\s*(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AuthenticationMethods)\b' "$f"; then
    cp -a "$f" "$f.bak.$(date +%s)"
    sed -ri 's/^(\s*)(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AuthenticationMethods)\b/\1# [grill] \2/I' "$f"
    warn "поправлен $f (бэкап рядом)"
  fi
done
shopt -u nullglob

PRL=$( ((DISABLE_ROOT)) && echo no || echo prohibit-password )
PWA=$( ((DISABLE_PWAUTH)) && echo no || echo yes )

cat > "$OURFILE" <<EOF
# Создано 02-ssh.sh $(date -Is) для пользователя $NEWUSER
# Этот файл читается раньше остальных (префикс 00-) и имеет приоритет.
PermitRootLogin $PRL
PasswordAuthentication $PWA
PubkeyAuthentication yes
EOF
# Доступ "пароль и ключ одновременно" → требуем ОБА фактора.
[[ $REQUIRE_BOTH -eq 1 ]] && echo "AuthenticationMethods publickey,password" >> "$OURFILE"
[[ "$SSH_PORT" != "22" ]] && echo "Port $SSH_PORT" >> "$OURFILE"
chmod 644 "$OURFILE"
ok "записан $OURFILE"

if sshd -t; then
  ok "sshd -t: синтаксис ок"
  if [[ $DISABLE_PWAUTH -eq 1 || $REQUIRE_BOTH -eq 1 ]]; then
    warn "Не закрывай текущую сессию — открой НОВЫЙ терминал и проверь вход"
    warn "до перезапуска (понадобятся ключ$( ((REQUIRE_BOTH)) && printf ' И пароль' ))."
  fi
  if confirm "Перезапустить ssh сейчас?" y; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
    ok "ssh перезапущен"
  else
    warn "Перезапусти вручную: systemctl restart ssh"
  fi
else
  err "sshd -t показал ошибку — конфиг НЕ применён, ssh не трогаю."
  exit 1
fi
say "Проверка входа:  ssh -p $SSH_PORT $NEWUSER@<IP>"
