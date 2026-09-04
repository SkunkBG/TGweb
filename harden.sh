#!/usr/bin/env bash
#
# TGweb — базовая защита и настройка сервера под WEB-прокси.
#   sudo bash harden.sh
#
# Делает четыре вещи, каждую можно отключить флагом:
#   1. Файрвол (ufw): запрет всего входящего, кроме SSH, 80 и 443.
#   2. fail2ban: защита SSH от перебора, с чтением journald.
#   3. Сетевой тюнинг: BBR + fq, очереди, лимиты.
#   4. Своп, лимит журнала, автообновления безопасности.
#
# Скрипт не трогает правила tproxy-firewall от установщика прокси: та таблица
# nftables (inet tproxy_backend) висит на своём хуке и закрывает 2398/8888
# снаружи. ufw работает в отдельной таблице, конфликта нет.
#
set -Eeuo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-tgweb.conf"
JOURNALD_FILE="/etc/systemd/journald.conf.d/99-tgweb.conf"
JAIL_FILE="/etc/fail2ban/jail.local"
SWAPFILE="/swapfile"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  RED=$'\033[31m'; OFF=$'\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; YELLOW=''; RED=''; OFF=''
fi
CURRENT_STEP="старт"
step() { CURRENT_STEP="$1"; printf '\n%s==> %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()   { printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$1"; }
warn() { printf '  %s!!%s   %s\n' "$YELLOW" "$OFF" "$1"; }
info() { printf '  %s·%s    %s\n' "$DIM" "$OFF" "$1"; }
die()  { printf '\n  %sошибка:%s %s\n\n' "$RED" "$OFF" "$1" >&2; exit 1; }

# Обрыв по set -e здесь опаснее, чем в install.sh: между сбросом ufw и его
# включением сервер остаётся без файрвола, и человек должен узнать об этом
# сразу, а не по оборванному выводу. die() уходит через exit и ERR не поднимает.
on_error() {
  local code="$1" line="$2" cmd="$3"
  printf '\n  %sсорвалось%s на шаге «%s»\n' "$RED" "$OFF" "$CURRENT_STEP" >&2
  printf '    строка %s, код выхода %s\n    команда: %s\n' "$line" "$code" "$cmd" >&2
  case "$CURRENT_STEP" in
    *"Файрвол"*)
      printf '\n    %sНЕ ЗАКРЫВАЙТЕ ЭТУ СЕССИЮ.%s Правила могли остаться сброшенными,\n' "$RED" "$OFF" >&2
      printf '    а ufw выключенным — сервер сейчас без файрвола. Проверьте:\n' >&2
      printf '      ufw status verbose\n' >&2
      printf '    Прежние правила ufw отложил в /etc/ufw/*.rules.<таймстамп>,\n' >&2
      printf '    вернуть: mv /etc/ufw/user.rules.<таймстамп> /etc/ufw/user.rules && ufw reload\n' >&2 ;;
    *"fail2ban"*)
      printf '\n    Конфиг: %s, прежний рядом с суффиксом .bak.\n' "$JAIL_FILE" >&2
      printf '    Проверка: fail2ban-client -t; журнал: journalctl -u fail2ban -n 40\n' >&2 ;;
    *"тюнинг"*)
      printf '\n    Откат: rm -f %s && sysctl --system\n' "$SYSCTL_FILE" >&2 ;;
    *"Своп"*|*"журнал"*|*"Автообновления"*)
      printf '\n    Файрвол и fail2ban к этому моменту уже настроены, это последний блок.\n' >&2 ;;
  esac
  printf '\n' >&2
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

DO_FIREWALL=1; DO_FAIL2BAN=1; DO_TUNING=1; DO_EXTRAS=1; ASSUME_YES=0
usage() {
  cat <<EOF
TGweb harden — защита и настройка сервера.

  sudo bash harden.sh [опции]

  --skip-firewall   не настраивать ufw
  --skip-fail2ban   не настраивать fail2ban
  --skip-tuning     не менять sysctl
  --skip-extras     не трогать своп, журнал и автообновления
  -y, --yes         без подтверждений
  -h, --help        справка
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-firewall) DO_FIREWALL=0; shift ;;
    --skip-fail2ban) DO_FAIL2BAN=0; shift ;;
    --skip-tuning)   DO_TUNING=0; shift ;;
    --skip-extras)   DO_EXTRAS=0; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ -t 0 ]] || die "Нет терминала для подтверждения — добавьте --yes."
  printf '  %s [y/N] > ' "$1"
  local a; IFS= read -r a || return 1
  case "${a:-}" in [yYдД]|[yY]es|да) return 0 ;; *) return 1 ;; esac
}

printf '\n%s  TGweb harden%s  %sзащита и настройка сервера%s\n' "$BOLD" "$OFF" "$DIM" "$OFF"

# ─────────────────────────────── окружение ────────────────────────────────
step "Проверка окружения"
[[ $EUID -eq 0 ]] || die "Нужны права root: sudo bash harden.sh"
command -v systemctl >/dev/null || die "Нет systemd."
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  ok "ОС: ${PRETTY_NAME:-${ID:-неизвестна}}"
  case "${ID:-}" in
    debian|ubuntu) : ;;
    *) warn "Скрипт рассчитан на Debian и Ubuntu. Продолжаю, но проверяйте вывод." ;;
  esac
fi
mem_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
ok "RAM ${mem_mb} МБ, ядер $(nproc)"

# порты SSH: sshd -T учитывает Include и Match, это самый надёжный источник
ssh_ports=()
if command -v sshd >/dev/null; then
  while IFS= read -r p; do [[ -n "$p" ]] && ssh_ports+=("$p"); done \
    < <(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' || true)
fi
if [[ ${#ssh_ports[@]} -eq 0 ]] && command -v ss >/dev/null; then
  while IFS= read -r p; do [[ -n "$p" ]] && ssh_ports+=("$p"); done \
    < <(ss -lntpH 2>/dev/null | awk '/sshd/{sub(/.*:/,"",$4); print $4}' | sort -u || true)
fi
[[ ${#ssh_ports[@]} -eq 0 ]] && ssh_ports=(22)

# порт, через который мы сейчас подключены — его закрыть нельзя ни в каком случае
admin_ip=""; live_port=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  # shellcheck disable=SC2206
  set -- ${SSH_CONNECTION}
  admin_ip="${1:-}"; live_port="${4:-}"
  [[ -n "$live_port" ]] && ok "Текущая SSH-сессия: порт $live_port, ваш IP $admin_ip"
  if [[ -n "$live_port" ]] && ! printf '%s\n' "${ssh_ports[@]}" | grep -qx "$live_port"; then
    ssh_ports+=("$live_port")
    warn "Порт $live_port не нашёлся в конфиге sshd — добавляю принудительно"
  fi
else
  warn "Не вижу переменной SSH_CONNECTION (локальная консоль?). Порты SSH: ${ssh_ports[*]}"
fi
ok "Порты SSH к разрешению: ${ssh_ports[*]}"

export DEBIAN_FRONTEND=noninteractive
apt_installed=0
apt_install() {
  if [[ $apt_installed -eq 0 ]]; then apt-get update -qq; apt_installed=1; fi
  apt-get install -y -qq "$@" >/dev/null
}

# ──────────────────────────────── 1. ufw ──────────────────────────────────
if [[ $DO_FIREWALL -eq 1 ]]; then
  step "Файрвол (ufw)"
  command -v ufw >/dev/null || { apt_install ufw; ok "ufw установлен"; }

  printf '\n  Будет применено:\n'
  printf '    входящие  : запрещены по умолчанию\n'
  printf '    исходящие : разрешены\n'
  for p in "${ssh_ports[@]}"; do
    printf '    разрешить : %s/tcp (SSH, с ограничением частоты)\n' "$p"
  done
  printf '    разрешить : 80/tcp, 443/tcp (Caddy)\n'

  # Раньше сброс шёл молча, и человек не видел, что теряет. ufw переносит
  # текущие файлы правил в /etc/ufw/*.rules.<таймстамп> (src/backend_iptables.py),
  # так что откат есть — но сказать об этом надо до, а не после.
  existing="$(ufw status numbered 2>/dev/null | sed -n '/^\[/p' || true)"
  if [[ -n "$existing" ]]; then
    printf '\n  %sТекущие правила будут сброшены%s — сейчас их %s:\n' \
      "$YELLOW" "$OFF" "$(printf '%s\n' "$existing" | wc -l | tr -d ' ')"
    printf '%s\n' "$existing" | sed 's/^/       /'
    printf '    Копии останутся в /etc/ufw/*.rules.<таймстамп>\n'
  fi
  printf '\n'

  if confirm "Применить?"; then
    # на несколько секунд между reset и enable сервер остаётся без файрвола
    reset_out="$(ufw --force reset 2>&1 || true)"
    printf '%s\n' "$reset_out" | grep -i "backing up" | sed 's/^/       /' || true
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    for p in "${ssh_ports[@]}"; do ufw limit "$p/tcp" comment 'SSH' >/dev/null; done
    ufw allow 80/tcp  comment 'HTTP ACME' >/dev/null
    ufw allow 443/tcp comment 'HTTPS carrier' >/dev/null
    ufw --force enable >/dev/null
    systemctl enable ufw >/dev/null 2>&1 || true
    ok "Правила применены"
    ufw status verbose | sed 's/^/       /'
    # контроль: SSH действительно разрешён
    for p in "${ssh_ports[@]}"; do
      ufw status | grep -q "^$p/tcp" \
        && ok "SSH-порт $p подтверждён в правилах" \
        || warn "SSH-порт $p НЕ виден в правилах — проверьте вручную, не разрывая сессию!"
    done
  else
    info "Файрвол не изменён"
  fi
fi

# ───────────────────────────── 2. fail2ban ────────────────────────────────
if [[ $DO_FAIL2BAN -eq 1 ]]; then
  step "fail2ban"
  # python3-systemd обязателен: без него backend = systemd не заработает
  apt_install fail2ban python3-systemd
  ok "fail2ban $(fail2ban-server --version 2>/dev/null | head -n1 | awk '{print $2}') и python3-systemd"

  # На Debian 12/13 и свежих Ubuntu /var/log/auth.log отсутствует (только
  # journald), а штатный jail sshd читает именно его и молча не стартует.
  # Поэтому backend = systemd. Но сам systemd-backend требует рабочего
  # python3-systemd, и это отдельная точка тихого отказа — проверяем импорт.
  f2b_backend="systemd"
  if python3 -c 'from systemd import journal' >/dev/null 2>&1; then
    ok "systemd-backend доступен (python3-systemd импортируется)"
    [[ -e /var/log/auth.log ]] \
      && info "/var/log/auth.log тоже есть, но journald надёжнее" \
      || ok "/var/log/auth.log отсутствует — journald тем более обязателен"
  elif [[ -s /var/log/auth.log ]]; then
    f2b_backend="auto"
    warn "python3-systemd не работает — беру файловый backend, /var/log/auth.log на месте"
  else
    warn "python3-systemd не работает, а /var/log/auth.log нет — jail не увидит логи!"
    warn "Лечится одним из двух: apt-get install --reinstall python3-systemd"
    warn "или apt-get install rsyslog (тогда появится /var/log/auth.log)."
  fi

  # Баним через ufw только если он реально включён, иначе правила уйдут в пустоту.
  f2b_banaction="ufw"
  if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    f2b_banaction="nftables-multiport"
    warn "ufw неактивен — баню через nftables-multiport"
  fi

  # При файловом backend путь задаём явно, чтобы не зависеть от paths-*.conf
  f2b_logpath=""
  [[ "$f2b_backend" != "systemd" ]] && f2b_logpath="logpath = /var/log/auth.log"

  jail_ports="$(IFS=,; printf '%s' "${ssh_ports[*]}")"
  ignore="127.0.0.1/8 ::1"
  [[ -n "$admin_ip" ]] && ignore="$ignore $admin_ip"

  [[ -e "$JAIL_FILE" ]] && cp -a "$JAIL_FILE" "$JAIL_FILE.bak.$(date +%Y%m%d%H%M%S)" \
    && info "Прежний jail.local сохранён рядом с суффиксом .bak"

  cat > "$JAIL_FILE" <<EOF
# Создано TGweb harden.sh — правьте свободно, скрипт делает резервную копию.
[DEFAULT]
# Логи SSH живут в journald: на Debian 12/13 и свежих Ubuntu файла
# /var/log/auth.log нет, и файловый backend тихо не стартует.
backend   = $f2b_backend

# Баним через ufw, чтобы правила не конфликтовали с его цепочками.
banaction = $f2b_banaction

bantime   = 1h
findtime  = 10m
maxretry  = 5

# Повторные визиты — всё более долгий бан, до недели.
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w

# Себя не баним.
ignoreip  = $ignore

[sshd]
enabled = true
port    = $jail_ports
$f2b_logpath
EOF
  chmod 644 "$JAIL_FILE"
  ok "Записан $JAIL_FILE (порты $jail_ports)"

  if fail2ban-client -t >/dev/null 2>&1; then
    ok "Конфигурация валидна"
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    sleep 3
    if systemctl is-active --quiet fail2ban; then
      ok "fail2ban активен"
      fail2ban-client status sshd 2>/dev/null | sed 's/^/       /' \
        || warn "Jail sshd не отвечает — смотрите journalctl -u fail2ban -n 40"
    else
      warn "fail2ban не поднялся — journalctl -u fail2ban -n 40 --no-pager"
    fi
  else
    warn "fail2ban-client -t сообщил об ошибке, сервис не перезапускаю:"
    fail2ban-client -t 2>&1 | tail -15 | sed 's/^/       /'
  fi

  # Ключи вместо паролей — это сильнее любого fail2ban, но выключать пароли
  # автоматически нельзя: можно отрезать себе доступ. Только подсказка.
  if sshd -T 2>/dev/null | grep -qi '^passwordauthentication yes'; then
    keys=0
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
      [[ -s "$f" ]] && keys=1
    done
    if [[ $keys -eq 1 ]]; then
      warn "Вход по паролю включён, но ключи уже настроены. Отключить пароли:"
      printf '         echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/99-no-password.conf\n'
      printf '         sshd -t && systemctl reload ssh\n'
      printf '         %s(сначала проверьте вход по ключу во втором окне!)%s\n' "$DIM" "$OFF"
    else
      warn "Вход по паролю включён, а ключей нет. Настройте ssh-copy-id — это важнее fail2ban."
    fi
  else
    ok "Вход по паролю уже отключён"
  fi
fi

# ─────────────────────────── 3. сетевой тюнинг ────────────────────────────
if [[ $DO_TUNING -eq 1 ]]; then
  step "Сетевой тюнинг"
  modprobe tcp_bbr 2>/dev/null || true
  bbr_ok=0
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && bbr_ok=1

  {
    printf '# Создано TGweb harden.sh\n\n'
    if [[ $bbr_ok -eq 1 ]]; then
      printf '# BBR заметно ровнее CUBIC на длинных и потерянных маршрутах,\n'
      printf '# а через прокси трафик идёт именно такими.\n'
      printf 'net.core.default_qdisc = fq\n'
      printf 'net.ipv4.tcp_congestion_control = bbr\n\n'
    fi
    printf '# Очереди приёма: одно ядро и много коротких соединений.\n'
    printf 'net.core.somaxconn = 8192\n'
    printf 'net.core.netdev_max_backlog = 16384\n'
    printf 'net.ipv4.tcp_max_syn_backlog = 8192\n\n'
    printf '# Исходящие соединения к дата-центрам Telegram: шире диапазон портов\n'
    printf '# и быстрее переиспользование освободившихся.\n'
    printf 'net.ipv4.ip_local_port_range = 10240 65535\n'
    printf 'net.ipv4.tcp_tw_reuse = 1\n'
    printf 'net.ipv4.tcp_fin_timeout = 15\n\n'
    printf '# Живучесть длинных сессий carrier и обход чёрных дыр MTU.\n'
    printf 'net.ipv4.tcp_mtu_probing = 1\n'
    printf 'net.ipv4.tcp_slow_start_after_idle = 0\n'
    printf 'net.ipv4.tcp_keepalive_time = 300\n'
    printf 'net.ipv4.tcp_keepalive_intvl = 30\n'
    printf 'net.ipv4.tcp_keepalive_probes = 5\n\n'
    printf '# Дескрипторы: юниты просят LimitNOFILE=1048576.\n'
    printf 'fs.file-max = 1048576\n\n'
    printf '# Мало памяти: своп нужен, но как страховка, а не как рабочий режим.\n'
    printf 'vm.swappiness = 10\n'
    printf 'vm.vfs_cache_pressure = 50\n'
  } > "$SYSCTL_FILE"

  [[ $bbr_ok -eq 1 ]] && ok "BBR доступен, включаю вместе с fq" \
                      || warn "BBR в ядре недоступен — оставляю штатный алгоритм"

  if sysctl --system >/dev/null 2>&1; then
    ok "Записан $SYSCTL_FILE и применён"
  else
    warn "Часть параметров ядро не приняло (бывает в контейнерах). Проверка ниже."
  fi
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  sm="$(sysctl -n net.core.somaxconn 2>/dev/null || echo '?')"
  info "сейчас: congestion=$cc qdisc=$qd somaxconn=$sm"
fi

# ──────────────────── 4. своп, журнал, автообновления ─────────────────────
if [[ $DO_EXTRAS -eq 1 ]]; then
  step "Своп"
  swap_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
  if [[ "${swap_kb:-0}" -gt 0 ]]; then
    ok "Своп уже есть ($((swap_kb / 1024)) МБ)"
  elif [[ -e "$SWAPFILE" ]]; then
    warn "$SWAPFILE существует, но не подключён — не трогаю, разберитесь вручную"
  elif [[ "$mem_mb" -ge 2048 ]]; then
    info "RAM ${mem_mb} МБ, своп не обязателен — пропускаю"
  else
    free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
    if [[ "${free_mb:-0}" -lt 3072 ]]; then
      warn "На / свободно ${free_mb} МБ — маловато для свопа, пропускаю"
    elif confirm "Создать своп-файл 1 ГБ (RAM всего ${mem_mb} МБ)?"; then
      if fallocate -l 1G "$SWAPFILE" 2>/dev/null || \
         dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024 status=none; then
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE" >/dev/null
        swapon "$SWAPFILE"
        grep -q "^$SWAPFILE " /etc/fstab || printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab
        ok "Своп 1 ГБ подключён и прописан в /etc/fstab"
      else
        warn "Не удалось создать своп-файл"
        rm -f "$SWAPFILE"
      fi
    else
      info "Своп не создан"
    fi
  fi

  step "Лимит журнала"
  mkdir -p "$(dirname "$JOURNALD_FILE")"
  cat > "$JOURNALD_FILE" <<'EOF'
# Создано TGweb harden.sh: journald по умолчанию может занять до 10% диска.
# На маленьком VPS это реальный риск заполнить раздел.
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=20M
MaxRetentionSec=1month
EOF
  ok "Записан $JOURNALD_FILE (лимит 200 МБ)"
  # Место освобождаем сразу и без рестарта — это безопасно.
  if journalctl --vacuum-size=200M >/dev/null 2>&1; then
    ok "Журнал ужат до 200 МБ прямо сейчас (journalctl --vacuum-size)"
  fi
  # А вот сам лимит journald читает только при старте. Рестарт при этом рвёт
  # stdout-потоки уже запущенных юнитов: их вывод пропадёт из журнала до
  # собственного рестарта. Поэтому спрашиваем, а не делаем молча.
  if confirm "Перезапустить systemd-journald, чтобы лимит действовал уже сейчас?"; then
    systemctl restart systemd-journald 2>/dev/null || true
    ok "journald перезапущен, лимит в силе"
    info "Сервисы, писавшие в журнал через stdout, стоит перезапустить, иначе"
    info "их вывод не попадёт в журнал до следующего рестарта."
  else
    info "Лимит вступит в силу после перезагрузки — файл на месте, ничего делать не надо"
  fi

  step "Автообновления безопасности"
  if confirm "Включить unattended-upgrades?"; then
    apt_install unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    ok "unattended-upgrades включены"
    info "Ядро обновляется, но перезагрузку надо делать вручную"
  else
    info "Автообновления не включены"
  fi
fi

# ─────────────────────────────── итог ────────────────────────────────────
step "Итог"
[[ $DO_FIREWALL -eq 1 ]] && { ufw status | head -n1 | sed 's/^/  /'; }
if [[ $DO_FAIL2BAN -eq 1 ]]; then
  systemctl is-active --quiet fail2ban \
    && printf '  fail2ban: active\n' || printf '  fail2ban: НЕ активен\n'
fi
cat <<EOF

  Проверить в любой момент:
    ufw status verbose
    fail2ban-client status sshd
    fail2ban-client set sshd unbanip <IP>        # разбанить
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
    bash status.sh                               # состояние прокси

${YELLOW}  Не закрывайте эту сессию,${OFF} пока не проверите вход вторым окном:
    ssh -p ${ssh_ports[0]} ${SUDO_USER:-$(id -un)}@<адрес сервера>

EOF
