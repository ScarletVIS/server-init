#!/usr/bin/env bash
#
# 08-proxy.sh — клиент прокси-туннеля через VLESS (Xray-core).
# Ставит Xray, разбирает ссылку вида vless://... из 3x-ui (Reality/TLS, tcp/ws/grpc)
# и поднимает локальный SOCKS5/HTTP-прокси как systemd-сервис. Дальше браузер или
# система ходят через заграничный сервер. Запуск отдельно: sudo ./modules/08-proxy.sh
#
# В отличие от остальных модулей это КЛИЕНТСКИЙ инструмент: запускать его надо на
# той машине (в РФ), с которой нужен доступ через прокси, а не на сервере с 3x-ui.
#
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/common.sh"
load_state
require_root

XRAY_CFG=/usr/local/etc/xray/config.json
INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

hdr "Прокси-туннель (VLESS → локальный SOCKS5/HTTP)"
confirm "Настроить локальный прокси через VLESS-ссылку?" n || { say "Пропуск."; exit 0; }

# ─── ввод vless:// ───────────────────────────────────────────────────────────
say "Вставь ссылку из 3x-ui (кнопка «копировать», формат vless://UUID@host:port?...#имя)."
URI=""
while :; do
  read -rp "vless:// ссылка: " URI || true
  URI="$(printf '%s' "$URI" | tr -d '[:space:]')"
  [[ "$URI" == vless://*@*:* ]] && break
  warn "Это не похоже на vless://UUID@host:port?... — попробуй ещё раз."
done

# ─── разбор ссылки ─────────────────────────────────────────────────────────────
urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

rest="${URI#vless://}"
TAG="proxy"
if [[ "$rest" == *#* ]]; then TAG="$(urldecode "${rest##*#}")"; rest="${rest%%#*}"; fi
QUERY=""
if [[ "$rest" == *\?* ]]; then QUERY="${rest#*\?}"; rest="${rest%%\?*}"; fi
UUID="${rest%@*}"
HOSTPORT="${rest##*@}"
SRV_HOST="${HOSTPORT%:*}"
SRV_PORT="${HOSTPORT##*:}"

declare -A Q=()
if [[ -n "$QUERY" ]]; then
  IFS='&' read -ra _pairs <<<"$QUERY"
  for _p in "${_pairs[@]}"; do
    [[ -z "$_p" ]] && continue
    Q["${_p%%=*}"]="$(urldecode "${_p#*=}")"
  done
fi

NET="${Q[type]:-tcp}"          # tcp | ws | grpc | ...
SEC="${Q[security]:-none}"     # none | tls | reality
FLOW="${Q[flow]:-}"
ENC="${Q[encryption]:-none}"

if [[ -z "$UUID" || -z "$SRV_HOST" ]] || ! valid_port "$SRV_PORT"; then
  err "Не удалось разобрать ссылку (UUID/host/port). Проверь, что скопировал её целиком."
  exit 1
fi

say ""
ok  "сервер:    $SRV_HOST:$SRV_PORT"
say "  транспорт: $NET, безопасность: $SEC${FLOW:+, flow: $FLOW}"
[[ "$SEC" != none && "$SEC" != tls && "$SEC" != reality ]] && \
  warn "security=$SEC пока не поддерживается этим скриптом — конфиг может не заработать."
[[ "$NET" != tcp && "$NET" != ws && "$NET" != grpc ]] && \
  warn "transport=$NET пока не поддерживается этим скриптом — конфиг может не заработать."

# ─── локальные порты прокси ────────────────────────────────────────────────────
ask_port() {                      # ask_port <переменная> <текст> <по умолчанию>
  local __var="$1" __msg="$2" __def="$3" __v
  while :; do
    read -rp "$__msg [$__def]: " __v || true
    __v="${__v:-$__def}"
    valid_port "$__v" && break
    warn "Порт должен быть числом 1..65535."
  done
  printf -v "$__var" '%s' "$__v"
}
ask_port SOCKS_PORT "Локальный SOCKS5-порт" 10808
ask_port HTTP_PORT  "Локальный HTTP-порт"   10809

LISTEN="127.0.0.1"
if confirm "Открыть прокси для всей локальной сети (0.0.0.0)? Иначе только localhost." n; then
  LISTEN="0.0.0.0"
  warn "Прокси будет доступен другим машинам в сети — следи за файрволом."
fi

# ─── маршрутизация: весь трафик или только выбранные сервисы ────────────────────
# В split-режиме через прокси идут только выбранные домены/IP, остальное — напрямую.
# Готовые наборы маппятся на категории geosite/geoip (данные ставит установщик Xray).
declare -a R_DOMAIN=() R_IP=()
add_preset() {
  case "$1" in
    telegram) R_DOMAIN+=("geosite:telegram"); R_IP+=("geoip:telegram") ;;
    google)   R_DOMAIN+=("geosite:google") ;;
    youtube)  R_DOMAIN+=("geosite:youtube") ;;
    openai)   R_DOMAIN+=("geosite:openai") ;;
    twitter)  R_DOMAIN+=("geosite:twitter"); R_IP+=("geoip:twitter") ;;
    meta)     R_DOMAIN+=("geosite:facebook" "geosite:instagram"); R_IP+=("geoip:facebook") ;;
    netflix)  R_DOMAIN+=("geosite:netflix"); R_IP+=("geoip:netflix") ;;
    discord)  R_DOMAIN+=("geosite:discord") ;;
  esac
}

say ""
say "Режим маршрутизации:"
say "  1) весь трафик через прокси"
say "  2) только выбранные сервисы через прокси (остальное — напрямую)"
ROUTE_MODE=1
while :; do
  read -rp "Выбор [1-2]: " ROUTE_MODE || true
  [[ "$ROUTE_MODE" =~ ^[12]$ ]] && break
  warn "Введи 1 или 2."
done

if [[ "$ROUTE_MODE" == 2 ]]; then
  declare -A PRESET=( [1]=telegram [2]=youtube [3]=google [4]=openai
                      [5]=twitter [6]=meta [7]=netflix [8]=discord )
  say ""
  say "Готовые наборы (можно несколько через пробел, например: 1 3):"
  say "  1) Telegram   2) YouTube   3) Google   4) OpenAI/ChatGPT"
  say "  5) Twitter/X  6) Instagram/Facebook  7) Netflix  8) Discord"
  read -rp "Номера наборов (пусто — пропустить): " _sel || true
  for _n in $_sel; do
    [[ -n "${PRESET[$_n]:-}" ]] && { add_preset "${PRESET[$_n]}"; ok "добавлено: ${PRESET[$_n]}"; } \
                                || warn "нет набора '$_n' — пропущен."
  done

  say ""
  say "Свои домены через прокси (например telegram.org). Пустая строка — конец."
  while :; do
    read -rp "Домен: " _d || true
    _d="$(printf '%s' "$_d" | tr -d '[:space:]')"
    [[ -z "$_d" ]] && break
    if [[ "$_d" == *:* ]]; then R_DOMAIN+=("$_d"); else R_DOMAIN+=("domain:$_d"); fi
    ok "добавлено: $_d"
  done

  if [[ ${#R_DOMAIN[@]} -eq 0 && ${#R_IP[@]} -eq 0 ]]; then
    warn "ничего не выбрано — включаю полный туннель (весь трафик через прокси)."
    ROUTE_MODE=1
  fi
fi

# ─── сборка streamSettings ─────────────────────────────────────────────────────
json_csv_array() {                # "h2,http/1.1" -> ["h2","http/1.1"]
  local out="" IFS=','; read -ra _a <<<"$1"
  for _e in "${_a[@]}"; do _e="${_e// /}"; [[ -z "$_e" ]] && continue; out+="${out:+,}\"$_e\""; done
  printf '[%s]' "$out"
}

SEC_JSON=""
case "$SEC" in
  tls)
    sni="${Q[sni]:-${Q[host]:-$SRV_HOST}}"; fp="${Q[fp]:-chrome}"
    SEC_JSON="\"tlsSettings\":{\"serverName\":\"$sni\",\"fingerprint\":\"$fp\",\"allowInsecure\":false"
    [[ -n "${Q[alpn]:-}" ]] && SEC_JSON+=",\"alpn\":$(json_csv_array "${Q[alpn]}")"
    SEC_JSON+="}"
    ;;
  reality)
    sni="${Q[sni]:-}"; fp="${Q[fp]:-chrome}"
    SEC_JSON="\"realitySettings\":{\"serverName\":\"$sni\",\"fingerprint\":\"$fp\",\"publicKey\":\"${Q[pbk]:-}\",\"shortId\":\"${Q[sid]:-}\",\"spiderX\":\"${Q[spx]:-/}\"}"
    ;;
esac

NET_JSON=""
case "$NET" in
  ws)
    NET_JSON="\"wsSettings\":{\"path\":\"${Q[path]:-/}\""
    [[ -n "${Q[host]:-}" ]] && NET_JSON+=",\"headers\":{\"Host\":\"${Q[host]}\"}"
    NET_JSON+="}"
    ;;
  grpc)
    multi=false; [[ "${Q[mode]:-}" == multi ]] && multi=true
    NET_JSON="\"grpcSettings\":{\"serviceName\":\"${Q[serviceName]:-}\",\"multiMode\":$multi}"
    ;;
  tcp)
    if [[ "${Q[headerType]:-none}" == http ]]; then
      NET_JSON="\"tcpSettings\":{\"header\":{\"type\":\"http\",\"request\":{\"path\":[\"${Q[path]:-/}\"],\"headers\":{\"Host\":[\"${Q[host]:-}\"]}}}}"
    fi
    ;;
esac

STREAM="\"network\":\"$NET\",\"security\":\"$SEC\""
[[ -n "$SEC_JSON" ]] && STREAM+=",$SEC_JSON"
[[ -n "$NET_JSON" ]] && STREAM+=",$NET_JSON"

USER_JSON="\"id\":\"$UUID\",\"encryption\":\"$ENC\""
[[ -n "$FLOW" ]] && USER_JSON+=",\"flow\":\"$FLOW\""

# ─── сборка routing (только для split-режима) ──────────────────────────────────
json_str_array() {                # элементы -> ["a","b"]
  local out="" e; for e in "$@"; do out+="${out:+,}\"$e\""; done; printf '[%s]' "$out"
}
ROUTING=""
if [[ "$ROUTE_MODE" == 2 ]]; then
  proxy_rule="{ \"type\": \"field\", \"outboundTag\": \"proxy\""
  [[ ${#R_DOMAIN[@]} -gt 0 ]] && proxy_rule+=", \"domain\": $(json_str_array "${R_DOMAIN[@]}")"
  [[ ${#R_IP[@]}     -gt 0 ]] && proxy_rule+=", \"ip\": $(json_str_array "${R_IP[@]}")"
  proxy_rule+=" }"
  ROUTING=",
  \"routing\": {
    \"domainStrategy\": \"IPIfNonMatch\",
    \"rules\": [
      $proxy_rule,
      { \"type\": \"field\", \"outboundTag\": \"direct\", \"network\": \"tcp,udp\" }
    ]
  }"
fi

# ─── установка Xray ────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
if ! command -v xray >/dev/null 2>&1; then
  say ""
  ok "ставлю Xray-core (официальный установщик XTLS)…"
  apt-get update -y || true
  apt-get install -y curl ca-certificates
  bash -c "$(curl -L "$INSTALL_URL")" @ install
else
  ok "Xray уже установлен: $(xray version 2>/dev/null | head -n1)"
fi

# ─── запись конфига ────────────────────────────────────────────────────────────
install -d -m 0755 "$(dirname "$XRAY_CFG")"
if [[ -f "$XRAY_CFG" ]]; then
  cp -a "$XRAY_CFG" "$XRAY_CFG.bak.$(date +%s)"
  warn "прежний конфиг сохранён рядом как *.bak.*"
fi

cat >"$XRAY_CFG" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks", "listen": "$LISTEN", "port": $SOCKS_PORT, "protocol": "socks",
      "settings": { "udp": true } },
    { "tag": "http",  "listen": "$LISTEN", "port": $HTTP_PORT,  "protocol": "http",
      "settings": {} }
  ],
  "outbounds": [
    { "tag": "proxy", "protocol": "vless",
      "settings": { "vnext": [ { "address": "$SRV_HOST", "port": $SRV_PORT,
        "users": [ { $USER_JSON } ] } ] },
      "streamSettings": { $STREAM } },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ]$ROUTING
}
JSON

# ─── проверка и запуск ─────────────────────────────────────────────────────────
say ""
if ! xray run -test -config "$XRAY_CFG" >/dev/null 2>&1; then
  err "Xray не принял конфиг. Вывод проверки:"
  xray run -test -config "$XRAY_CFG" || true
  exit 1
fi
ok "конфиг валиден"

systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
  ok "сервис xray запущен (подключение «$TAG»)"
else
  err "сервис xray не поднялся — смотри: journalctl -u xray -e"
  exit 1
fi

# проверка выхода через прокси (в split-режиме ipify не маршрутизируется в прокси,
# поэтому сверяем IP напрямую и через SOCKS — они должны различаться)
if command -v curl >/dev/null 2>&1; then
  IP_PROXY="$(curl -s --max-time 12 --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://api.ipify.org 2>/dev/null || true)"
  if [[ "$ROUTE_MODE" == 2 ]]; then
    IP_DIRECT="$(curl -s --max-time 12 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "$IP_PROXY" ]]; then
      ok "проверка: прокси отвечает, исходящий IP — $IP_PROXY (прямой — ${IP_DIRECT:-?})"
      [[ -n "$IP_DIRECT" && "$IP_PROXY" == "$IP_DIRECT" ]] && \
        warn "IP совпали — для несписочных сайтов это норма (они идут напрямую)."
    else
      warn "прокси не ответил — проверь ссылку/доступность сервера."
    fi
  else
    if [[ -n "$IP_PROXY" ]]; then
      ok "проверка: внешний IP через прокси — $IP_PROXY"
    else
      warn "не удалось проверить выход через прокси — проверь ссылку/доступность сервера."
    fi
  fi
fi

hdr "Как пользоваться"
if [[ "$ROUTE_MODE" == 2 ]]; then
  say "Режим: split — через прокси только выбранные сервисы, остальное напрямую."
  say "  через прокси: ${R_DOMAIN[*]} ${R_IP[*]}"
else
  say "Режим: полный туннель — весь трафик идёт через прокси."
fi
say "SOCKS5: $LISTEN:$SOCKS_PORT      HTTP: $LISTEN:$HTTP_PORT"
say "Браузер/система → прокси SOCKS5 на $LISTEN:$SOCKS_PORT (с DNS через прокси)."
say "Терминал:  export ALL_PROXY=socks5h://127.0.0.1:$SOCKS_PORT"
say "Управление: systemctl {status|restart|stop} xray   логи: journalctl -u xray -f"
say "Сменить подключение — запусти модуль ещё раз с новой ссылкой."
