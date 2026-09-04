#!/usr/bin/env bash
#
# TGweb — удаление того, что поставил install.sh.
#   sudo bash uninstall.sh
#
# Best-effort: убирает юниты и файлы, которые создаёт deploy/install.sh
# из tproxy-server. Двоичные файлы в /usr/local/bin спрашиваются отдельно —
# если Caddy у вас стоял до этого, его лучше не трогать.
#
set -uo pipefail

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; OFF=$'\033[0m'
else
  BOLD=''; YELLOW=''; GREEN=''; OFF=''
fi
ok(){ printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$1"; }
step(){ printf '\n%s==> %s%s\n' "$BOLD" "$1" "$OFF"; }

[[ $EUID -eq 0 ]] || { echo "Нужны права root: sudo bash uninstall.sh" >&2; exit 1; }

confirm() {
  local q="$1"
  [[ "${TGWEB_YES:-0}" == "1" ]] && return 0
  printf '  %s [y/N] > ' "$q"
  local a; IFS= read -r a || return 1
  case "${a:-}" in [yYдД]|[yY]es|да) return 0 ;; *) return 1 ;; esac
}

printf '\n%s  TGweb — удаление%s\n' "$BOLD" "$OFF"
printf '\n%s  Будут остановлены сервисы и удалены конфиги прокси.%s\n' "$YELLOW" "$OFF"
confirm "Продолжить?" || { printf '\n  Отменено.\n\n'; exit 0; }

step "Остановка сервисов"
for svc in tproxy-server mtproxy caddy tproxy-firewall refresh-mtproxy-config.timer refresh-mtproxy-config; do
  systemctl disable --now "$svc" >/dev/null 2>&1 && ok "$svc остановлен и отключён" || true
done

step "Удаление unit-файлов"
for u in tproxy-server mtproxy caddy tproxy-firewall refresh-mtproxy-config; do
  for p in "/etc/systemd/system/$u.service" "/etc/systemd/system/$u.timer" \
           "/lib/systemd/system/$u.service"; do
    [[ -e "$p" ]] && rm -f "$p" && ok "удалён $p"
  done
done
systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

step "Удаление конфигов и данных"
for d in /etc/tproxy-server /etc/mtproxy /etc/caddy /srv/tproxy-site /opt/tgweb-site /etc/tgweb; do
  [[ -e "$d" ]] && rm -rf "$d" && ok "удалён $d"
done
if [[ -e /usr/local/sbin/refresh-mtproxy-config ]]; then
  rm -f /usr/local/sbin/refresh-mtproxy-config && ok "удалён /usr/local/sbin/refresh-mtproxy-config"
fi

step "Двоичные файлы"
if confirm "Удалить /usr/local/bin/tproxy-server?"; then
  rm -f /usr/local/bin/tproxy-server && ok "удалён /usr/local/bin/tproxy-server"
fi
if confirm "Удалить /usr/local/bin/caddy? (не удаляйте, если Caddy стоял до TGweb)"; then
  rm -f /usr/local/bin/caddy && ok "удалён /usr/local/bin/caddy"
fi
if confirm "Удалить исходники /opt/tproxy-src?"; then
  rm -rf /opt/tproxy-src && ok "удалён /opt/tproxy-src"
fi

printf '\n  Готово. Сертификаты Caddy могли остаться в /var/lib/caddy —\n'
printf '  удалите вручную, если они больше не нужны.\n\n'
