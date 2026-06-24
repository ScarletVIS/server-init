#!/usr/bin/env bash
#
# 06-project.sh — развернуть проект из git в ~/<папка> нового пользователя.
# Доступ: публичный / SSH deploy-ключ (генерируется) / токен по HTTPS.
# Токен передаётся через GIT_ASKPASS — он не попадает ни в argv, ни в env.
# Запуск отдельно:  sudo ./modules/06-project.sh
#
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"
load_state
require_root

hdr "Проект из git"
confirm "Развернуть проект из git?" n || { say "Пропуск."; exit 0; }
ensure_user

# URL
while :; do
  read -rp "URL репозитория (git@host:org/repo.git или https://...): " GIT_URL || true
  [[ -n "$GIT_URL" ]] && break
  warn "URL не может быть пустым."
done

# имя папки (по умолчанию из URL)
base="${GIT_URL##*/}"; base="${base%.git}"
while :; do
  read -rp "Имя папки в ~/ [$base]: " PROJECT_DIR || true
  PROJECT_DIR="${PROJECT_DIR:-$base}"
  [[ "$PROJECT_DIR" =~ ^[A-Za-z0-9._-]+$ ]] && break
  warn "Имя папки: только [A-Za-z0-9._-], без слешей."
done

# способ доступа
say ""
say "Доступ к репозиторию:"
say "  1) публичный / без авторизации"
say "  2) SSH deploy-ключ (сгенерирую пару, публичный покажу)"
say "  3) токен по HTTPS"
while :; do
  read -rp "Выбор [1-3]: " a || true
  case "$a" in
    1) GIT_AUTH="none";  break ;;
    2) GIT_AUTH="key";   break ;;
    3) GIT_AUTH="token"; break ;;
    *) warn "Введи 1, 2 или 3." ;;
  esac
done
GIT_TOKEN=""
if [[ "$GIT_AUTH" == token ]]; then
  while :; do
    read -rsp "Токен (ввод скрыт): " GIT_TOKEN || true; echo
    [[ -n "$GIT_TOKEN" ]] && break
    warn "Токен пустой."
  done
fi

# ─── выполнение ──────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
command -v git >/dev/null 2>&1 || { apt-get update -y || true; apt-get install -y git; }

HOME_DIR="$(getent passwd "$NEWUSER" | cut -d: -f6)"
DEST="$HOME_DIR/$PROJECT_DIR"
[[ -e "$DEST" ]] && { warn "Папка $DEST уже существует — клонирование пропущено."; exit 0; }
install -d -m 700 -o "$NEWUSER" -g "$NEWUSER" "$HOME_DIR/.ssh"

clone_ok=0
case "$GIT_AUTH" in
  none)
    runuser -u "$NEWUSER" -- git clone "$GIT_URL" "$DEST" && clone_ok=1 || true
    ;;

  key)
    KEYFILE="$HOME_DIR/.ssh/id_${PROJECT_DIR}"
    if [[ ! -f "$KEYFILE" ]]; then
      runuser -u "$NEWUSER" -- ssh-keygen -t ed25519 -N "" \
        -f "$KEYFILE" -C "${NEWUSER}@$(hostname -s 2>/dev/null || hostname)-${PROJECT_DIR}" >/dev/null
    fi
    say ""
    warn "Добавь этот ПУБЛИЧНЫЙ ключ как deploy key в репозиторий:"
    say "────────────────────────────────────────────────────────"
    cat "${KEYFILE}.pub"
    say "────────────────────────────────────────────────────────"
    read -rp "Enter, когда ключ добавлен (Ctrl-C — отмена)... " _ || true
    runuser -u "$NEWUSER" -- env \
      GIT_SSH_COMMAND="ssh -i $KEYFILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
      git clone "$GIT_URL" "$DEST" && clone_ok=1 || true
    if [[ $clone_ok -eq 1 ]]; then
      # закрепляем ключ для будущих git-операций в этом репо
      runuser -u "$NEWUSER" -- git -C "$DEST" config core.sshCommand \
        "ssh -i $KEYFILE -o IdentitiesOnly=yes"
    fi
    ;;

  token)
    case "$GIT_URL" in
      https://*) auth_url="https://x-access-token@${GIT_URL#https://}" ;;
      http://*)  auth_url="http://x-access-token@${GIT_URL#http://}"   ;;
      *) err "Токен поддерживается только для http(s)-URL."; exit 1 ;;
    esac
    # GIT_ASKPASS: токен лежит в файле 0600 пользователя, askpass его отдаёт git'у.
    # В argv и env токена нет — виден лишь путь к скриптам.
    TOKFILE="$HOME_DIR/.git-token.$$"
    ASKPASS="$HOME_DIR/.git-askpass.$$"
    cleanup() { rm -f "$TOKFILE" "$ASKPASS"; }
    trap cleanup EXIT
    ( umask 077; printf '%s\n' "$GIT_TOKEN" > "$TOKFILE" )
    cat > "$ASKPASS" <<EOF
#!/usr/bin/env bash
cat "$TOKFILE"
EOF
    chmod 700 "$ASKPASS"
    chown "$NEWUSER:$NEWUSER" "$TOKFILE" "$ASKPASS"
    runuser -u "$NEWUSER" -- env \
      GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 \
      git clone "$auth_url" "$DEST" && clone_ok=1 || true
    cleanup; trap - EXIT
    if [[ $clone_ok -eq 1 ]]; then
      # сохраняем чистый remote (без токена/служебного юзера)
      runuser -u "$NEWUSER" -- git -C "$DEST" remote set-url origin "$GIT_URL"
    fi
    ;;
esac

if [[ $clone_ok -eq 1 ]]; then
  ok "проект склонирован в $DEST"
else
  warn "клонирование не удалось — проверь URL/доступ."
fi
