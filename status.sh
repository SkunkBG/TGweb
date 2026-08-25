#!/usr/bin/env bash
#
# TGweb — быстрая сводка: сервисы, health, метрики, ссылка на подключение.
#   sudo bash status.sh
#
set -uo pipefail

STATE_DIR="/etc/tgweb"
SECRET_FILE="$STATE_DIR/secret"
PROFILES="/etc/tproxy-server/profiles.json"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'
  CYAN=$'\033[36m'; OFF=$'\033[0m'
else
  BOLD=''; GREEN=''; RED=''; DIM=''; CYAN=''; OFF=''
fi

[[ $EUID -eq 0 ]] || { echo "Нужны права root: sudo bash status.sh" >&2; exit 1; }

printf '\n%s  TGweb — состояние%s\n' "$BOLD" "$OFF"

printf '\n%s  сервисы%s\n' "$BOLD" "$OFF"
for svc in caddy tproxy-server mtproxy tproxy-firewall; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    printf '    %s●%s %-18s active   %ssince %s%s\n' "$GREEN" "$OFF" "$svc" "$DIM" \
      "$(systemctl show -p ActiveEnterTimestamp --value "$svc" 2>/dev/null | cut -d' ' -f2-3)" "$OFF"
  elif systemctl list-unit-files "$svc.service" >/dev/null 2>&1 \
       && systemctl cat "$svc" >/dev/null 2>&1; then
    printf '    %s●%s %-18s НЕ активен  %s(journalctl -u %s -n 50)%s\n' \
      "$RED" "$OFF" "$svc" "$DIM" "$svc" "$OFF"
  else
    printf '    %s○%s %-18s не установлен\n' "$DIM" "$OFF" "$svc"
  fi
done

printf '\n%s  health (loopback)%s\n' "$BOLD" "$OFF"
for ep in healthz readyz; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8081/$ep" 2>/dev/null || true)"
  [[ -n "$code" ]] || code="000"
  if [[ "$code" == "200" ]]; then
    printf '    %s●%s /%-8s %s\n' "$GREEN" "$OFF" "$ep" "$code"
  else
    printf '    %s●%s /%-8s %s\n' "$RED" "$OFF" "$ep" "$code"
  fi
done

printf '\n%s  метрики%s\n' "$BOLD" "$OFF"
if metrics="$(curl -fsS --max-time 5 http://127.0.0.1:8081/metrics 2>/dev/null)"; then
  printf '%s\n' "$metrics" | head -n 25 | sed 's/^/    /'
  lines="$(printf '%s\n' "$metrics" | wc -l)"
  (( lines > 25 )) && printf '    %s… ещё %s строк: curl -s http://127.0.0.1:8081/metrics%s\n' \
    "$DIM" "$(( lines - 25 ))" "$OFF"
else
  printf '    недоступны\n'
fi

# домен и секрет
host=""
if [[ -r /etc/tproxy-server/config.json ]]; then
  host="$(grep -oE '"hostname"[[:space:]]*:[[:space:]]*"[^"]+"' /etc/tproxy-server/config.json 2>/dev/null \
          | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi
[[ -z "$host" && -r /etc/caddy/Caddyfile.tproxy ]] && \
  host="$(grep -oE '^[a-z0-9.-]+\.[a-z]{2,}' /etc/caddy/Caddyfile.tproxy 2>/dev/null | head -n1)"

secret=""
[[ -r "$SECRET_FILE" ]] && secret="$(tr -d '[:space:]' < "$SECRET_FILE")"
if [[ -z "$secret" && -r "$PROFILES" ]]; then
  secret="$(grep -oE '"secret"[[:space:]]*:[[:space:]]*"[0-9a-f]{32,34}"' "$PROFILES" 2>/dev/null \
            | head -n1 | grep -oE '[0-9a-f]{32,34}')"
fi

printf '\n%s  подключение%s\n' "$BOLD" "$OFF"
if [[ -n "$host" && -n "$secret" ]]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/" 2>/dev/null || true)"
  [[ -n "$code" ]] || code="000"
  printf '    сайт снаружи : https://%s/ -> %s\n' "$host" "$code"
  printf '    тип прокси   : WEB\n'
  printf '    hostname     : %s%s%s\n' "$CYAN" "$host" "$OFF"
  printf '    secret       : %s%s%s\n' "$CYAN" "$secret" "$OFF"
  printf '\n    %shttps://t.me/webproxy?server=%s&secret=%s%s\n' "$GREEN" "$host" "$secret" "$OFF"
else
  printf '    Не удалось определить домен или секрет.\n'
  printf '    Смотрите %s и %s\n' "$STATE_DIR/info.txt" "$PROFILES"
fi
printf '\n'
