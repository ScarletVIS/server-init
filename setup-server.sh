#!/usr/bin/env bash
#
# setup-server.sh — оркестратор первоначальной настройки свежего Ubuntu.
# Сам ничего не делает руками: собирает общие параметры (пользователь, тип
# доступа) один раз и по очереди запускает модули из ./modules. Каждый модуль
# самодостаточен и может запускаться отдельно:
#
#   sudo ./setup-server.sh            # всё по шагам, с вопросом перед каждым
#   sudo ./modules/02-ssh.sh          # только харденинг SSH
#   sudo ./modules/05-packages.sh make git htop
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/common.sh"
require_root

. /etc/os-release 2>/dev/null || true
say "ОС: ${PRETTY_NAME:-неизвестно}"

# общий файл состояния — модули делятся через него NEWUSER/ACCESS/SSH_PORT
export SETUP_STATE
SETUP_STATE="$(mktemp /tmp/setup-server.XXXXXX.env)"
trap 'rm -f "$SETUP_STATE"' EXIT

# собираем общие параметры один раз, чтобы модули не переспрашивали
hdr "Общие параметры"
ensure_user
ensure_access

# по очереди предлагаем шаги
run_step() {                      # run_step <файл-модуля> <описание>
  local mod="$1" desc="$2"
  say ""
  if confirm "Шаг: $desc — выполнить?" y; then
    bash "$HERE/modules/$mod" || warn "шаг '$desc' завершился с ошибкой — продолжаю."
  else
    say "  пропущено: $desc"
  fi
}

run_step 01-user.sh     "пользователь (sudo / пароль / ключи)"
run_step 02-ssh.sh      "харденинг SSH"
run_step 03-fail2ban.sh "fail2ban"
run_step 04-docker.sh   "Docker"
run_step 05-packages.sh "дополнительные пакеты"
run_step 06-project.sh  "проект из git"

hdr "Готово"
ok "Сервер настроен."
