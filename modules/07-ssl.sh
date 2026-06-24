#!/usr/bin/env bash
#
# 07-ssl.sh — выпуск SSL-сертификата Let's Encrypt (certbot) на домен.
# Режимы: nginx / apache / standalone / webroot. Автопродление certbot ставит
# системным таймером сам. Запуск отдельно:  sudo ./modules/07-ssl.sh
#
# Важно: A/AAAA-запись домена должна указывать на этот сервер, а порты 80/443
# быть доступны снаружи — иначе валидация Let's Encrypt не пройдёт.
#
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"
load_state
require_root

valid_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

hdr "SSL-сертификат (Let's Encrypt)"
confirm "Выпустить SSL-сертификат на домен?" n || { say "Пропуск."; exit 0; }

# домены (можно несколько: example.com www.example.com ...)
declare -a DOMAINS=()
say "Вводи домены по одному (example.com, www.example.com). Пустая строка — конец."
while :; do
  read -rp "Домен: " d || true
  if [[ -z "$d" ]]; then
    [[ ${#DOMAINS[@]} -eq 0 ]] && { warn "Нужен хотя бы один домен."; continue; }
    break
  fi
  if valid_domain "$d"; then
    DOMAINS+=("$d"); ok "принят (${#DOMAINS[@]})"
  else
    warn "Не похоже на доменное имя — пропущен."
  fi
done

# email для уведомлений об истечении
read -rp "Email для Let's Encrypt (пусто — без email): " LE_EMAIL || true

# способ валидации/установки
say ""
say "Способ выпуска:"
say "  1) nginx      (certbot сам пропишет сертификат в конфиг nginx)"
say "  2) apache     (certbot сам пропишет сертификат в конфиг apache)"
say "  3) standalone (поднимет временный сервер на :80 — веб-сервер должен быть остановлен)"
say "  4) webroot    (указать каталог, который уже отдаёт работающий веб-сервер)"
while :; do
  read -rp "Выбор [1-4]: " m || true
  case "$m" in
    1) METHOD=nginx;      break ;;
    2) METHOD=apache;     break ;;
    3) METHOD=standalone; break ;;
    4) METHOD=webroot;    break ;;
    *) warn "Введи 1, 2, 3 или 4." ;;
  esac
done

WEBROOT=""
if [[ "$METHOD" == webroot ]]; then
  while :; do
    read -rp "Каталог webroot (например /var/www/html): " WEBROOT || true
    [[ -n "$WEBROOT" && -d "$WEBROOT" ]] && break
    warn "Каталог не существует."
  done
fi

REDIRECT=0
if [[ "$METHOD" == nginx || "$METHOD" == apache ]]; then
  confirm "Включить редирект HTTP→HTTPS?" y && REDIRECT=1
fi

STAGING=0
say ""
say "Тестовый (staging) сертификат — из тестового окружения Let's Encrypt."
say "  • не тратит боевые лимиты (5 неудач/час, 50 серт./неделю на домен);"
say "  • браузеры ему НЕ доверяют (подписан тестовым CA) — будет ошибка в браузере;"
say "  • годится, чтобы проверить, что DNS/порты/конфиг настроены верно,"
say "    а потом перевыпустить боевой: certbot delete --cert-name <домен> и запустить без staging."
say "Бери staging, если выпускаешь впервые и не уверен в DNS/портах. Иначе — нет."
confirm "Сделать тестовый (staging) сертификат?" n && STAGING=1

# ─── выполнение ──────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || true
case "$METHOD" in
  nginx)  apt-get install -y certbot python3-certbot-nginx  ;;
  apache) apt-get install -y certbot python3-certbot-apache ;;
  *)      apt-get install -y certbot                        ;;
esac

# для nginx/apache плагин правит конфиг существующего сервера — предупредим, если его нет
if [[ "$METHOD" == nginx  ]] && ! command -v nginx  >/dev/null 2>&1; then
  warn "nginx не найден в системе — certbot не сможет прописать сертификат."
fi
if [[ "$METHOD" == apache ]] && ! command -v apache2 >/dev/null 2>&1; then
  warn "apache2 не найден в системе — certbot не сможет прописать сертификат."
fi

# собираем аргументы certbot
declare -a ARGS=()
case "$METHOD" in
  nginx)      ARGS+=(--nginx) ;;
  apache)     ARGS+=(--apache) ;;
  standalone) ARGS+=(certonly --standalone) ;;
  webroot)    ARGS+=(certonly --webroot -w "$WEBROOT") ;;
esac
for d in "${DOMAINS[@]}"; do ARGS+=(-d "$d"); done
if [[ -n "$LE_EMAIL" ]]; then
  ARGS+=(-m "$LE_EMAIL")
else
  ARGS+=(--register-unsafely-without-email)
fi
ARGS+=(--agree-tos -n)
if [[ "$METHOD" == nginx || "$METHOD" == apache ]]; then
  (( REDIRECT )) && ARGS+=(--redirect) || ARGS+=(--no-redirect)
fi
(( STAGING )) && ARGS+=(--staging)

say ""
ok "запуск: certbot ${ARGS[*]}"
if certbot "${ARGS[@]}"; then
  ok "сертификат выпущен для: ${DOMAINS[*]}"
  if systemctl list-timers 'certbot*' --no-pager 2>/dev/null | grep -qi certbot; then
    ok "автопродление: таймер certbot активен"
  else
    warn "проверь автопродление вручную: systemctl status certbot.timer"
  fi
  certbot certificates 2>/dev/null || true
else
  err "certbot завершился с ошибкой — сертификат не выпущен."
  exit 1
fi
