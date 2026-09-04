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
for svc in tproxy-server mtproxy tproxy-firewall refresh-mtproxy-config.timer refresh-mtproxy-config; do
  systemctl disable --now "$svc" >/dev/null 2>&1 && ok "$svc остановлен и отключён" || true
done
# caddy останавливаем, но не отключаем вслепую: он мог стоять до TGweb.
# Решение об отключении принимается ниже, когда станет видно, был ли бэкап.
systemctl stop caddy >/dev/null 2>&1 && ok "caddy остановлен" || true

step "Удаление unit-файлов"
# /lib/systemd/system не трогаем принципиально: там лежат файлы пакетов dpkg,
# и удаление caddy.service оттуда сломало бы Caddy, поставленный из apt.
# Установщик апстрима кладёт свои юниты только в /etc/systemd/system.
for u in tproxy-server mtproxy tproxy-firewall refresh-mtproxy-config; do
  for p in "/etc/systemd/system/$u.service" "/etc/systemd/system/$u.timer"; do
    [[ -e "$p" ]] && rm -f "$p" && ok "удалён $p"
  done
done

step "Caddy"
# Апстрим перезаписывает /etc/systemd/system/caddy.service и /etc/caddy/Caddyfile,
# сохраняя прежние рядом как *.before-tproxy.<таймстамп>. Если бэкап есть —
# возвращаем его; если нет, значит Caddy пришёл вместе с TGweb, и свои файлы
# можно убрать. Каталог /etc/caddy целиком не сносим.
caddy_unit="/etc/systemd/system/caddy.service"
unit_backup=""
for f in "$caddy_unit".before-tproxy.*; do [[ -e "$f" ]] && unit_backup="$f"; done
if [[ -n "$unit_backup" ]]; then
  mv -f "$unit_backup" "$caddy_unit" && ok "возвращён прежний caddy.service из ${unit_backup##*/}"
elif [[ -e "$caddy_unit" ]]; then
  rm -f "$caddy_unit" && ok "удалён $caddy_unit"
  systemctl disable caddy >/dev/null 2>&1 && ok "caddy отключён из автозапуска" || true
fi

if [[ -e /etc/systemd/system/caddy.service.d/tproxy.conf ]]; then
  rm -f /etc/systemd/system/caddy.service.d/tproxy.conf && ok "удалён drop-in caddy.service.d/tproxy.conf"
  rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true
fi

[[ -e /etc/caddy/Caddyfile.tproxy ]] && rm -f /etc/caddy/Caddyfile.tproxy && ok "удалён /etc/caddy/Caddyfile.tproxy"
cf_backup=""
for f in /etc/caddy/Caddyfile.before-tproxy.*; do [[ -e "$f" ]] && cf_backup="$f"; done
if [[ -n "$cf_backup" ]]; then
  mv -f "$cf_backup" /etc/caddy/Caddyfile && ok "возвращён прежний Caddyfile из ${cf_backup##*/}"
elif [[ -e /etc/caddy/Caddyfile ]]; then
  rm -f /etc/caddy/Caddyfile && ok "удалён /etc/caddy/Caddyfile"
fi
rmdir /etc/caddy 2>/dev/null && ok "пустой /etc/caddy удалён" || true

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

step "Удаление конфигов и данных"
for d in /etc/tproxy-server /etc/mtproxy /srv/tproxy-site /opt/tgweb-site /etc/tgweb; do
  [[ -e "$d" ]] && rm -rf "$d" && ok "удалён $d"
done
# копии сайта, которые оставляет install.sh при повторных запусках
for d in /srv/tproxy-site.bak.* /srv/tproxy-site.new; do
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
printf '  удалите вручную, если они больше не нужны.\n'
if [[ -e /etc/caddy/Caddyfile || -e /etc/systemd/system/caddy.service ]]; then
  printf '\n%s  Caddy восстановлен из прежней конфигурации и НЕ запущен.%s\n' "$YELLOW" "$OFF"
  printf '  Проверьте и поднимите сами: caddy validate --config /etc/caddy/Caddyfile\n'
  printf '  затем systemctl start caddy\n'
fi
printf '\n'
