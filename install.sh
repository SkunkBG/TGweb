#!/usr/bin/env bash
#
# TGweb — интерактивная установка Telegram WEB-прокси (tproxy-server)
#         вместе с сайтом-прикрытием.
#
#   sudo bash install.sh
#
# Неинтерактивно:
#   sudo bash install.sh --hostname proxy.example.com --email you@example.com \
#                        --project Soul --yes
#
set -euo pipefail

VERSION="1.0.0"
UPSTREAM_REPO="https://github.com/telegramdesktop/tproxy-server.git"
SRC_DIR="/opt/tproxy-src"
BUILD_DIR="/opt/tgweb-site"
STATE_DIR="/etc/tgweb"
SECRET_FILE="$STATE_DIR/secret"
INFO_FILE="$STATE_DIR/info.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_SRC="$SCRIPT_DIR/site"
DRY_RUN="${TGWEB_DRY_RUN:-0}"

# ─────────────────────────────── оформление ───────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  RED=$'\033[31m'; CYAN=$'\033[36m'; OFF=$'\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; YELLOW=''; RED=''; CYAN=''; OFF=''
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()   { printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$1"; }
warn() { printf '  %s!!%s   %s\n' "$YELLOW" "$OFF" "$1"; }
info() { printf '  %s·%s    %s\n' "$DIM" "$OFF" "$1"; }
die()  { printf '\n  %sошибка:%s %s\n\n' "$RED" "$OFF" "$1" >&2; exit 1; }

# ──────────────────────────── разбор аргументов ───────────────────────────
FQDN=""; EMAIL=""; PROJECT=""; SECRET=""; WORKERS=""; ASSUME_YES=0; SKIP_DNS=0

usage() {
  cat <<EOF
TGweb $VERSION — установка Telegram WEB-прокси с сайтом-прикрытием.

  sudo bash install.sh [опции]

Опции (всё, что не указано, будет спрошено интерактивно):
  --hostname FQDN      домен прокси, например proxy.example.com
  --email ADDR         email для Let's Encrypt
  --project NAME       название проекта для сайта-прикрытия
  --secret HEX         32 hex-символа (по умолчанию генерируется случайный)
  --workers N          воркеров MTProxy (по умолчанию по числу ядер, максимум 4)
  --skip-dns-check     не сверять A-запись с внешним IP
  -y, --yes            не спрашивать подтверждение
  -h, --help           эта справка
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) FQDN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --secret) SECRET="${2:-}"; shift 2 ;;
    --workers) WORKERS="${2:-}"; shift 2 ;;
    --skip-dns-check) SKIP_DNS=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

printf '\n%s  TGweb %s%s  %sTelegram WEB-прокси + сайт-прикрытие%s\n' \
  "$BOLD" "$VERSION" "$OFF" "$DIM" "$OFF"

# ──────────────────────────── проверки системы ────────────────────────────
step "Проверка системы"
if [[ "$DRY_RUN" != "1" ]]; then
  [[ $EUID -eq 0 ]] || die "Нужны права root. Запустите: sudo bash install.sh"
fi
[[ -d "$SITE_SRC" ]] || die "Не найден каталог site/ рядом со скриптом.
     Запускайте install.sh из корня клонированного репозитория."
[[ -f "$SITE_SRC/index.html" ]] || die "В site/ нет index.html — это обязательный файл."

if [[ "$DRY_RUN" != "1" ]]; then
  [[ "$(uname -m)" == "x86_64" ]] || die "tproxy-server собирается только под x86_64, здесь $(uname -m)."
  command -v systemctl >/dev/null || die "Нет systemd."
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${VERSION_ID%%.*}" in
      ubuntu:2[2-9]|ubuntu:[3-9][0-9]|debian:1[2-9]|debian:[2-9][0-9])
        ok "ОС: ${PRETTY_NAME:-$ID}" ;;
      *) warn "ОС ${PRETTY_NAME:-неизвестна} вне протестированного списка (Ubuntu 22.04+, Debian 12+)." ;;
    esac
  fi
  ok "CPU: $(nproc) ядер, RAM: $(awk '/MemTotal/{printf "%d МБ", $2/1024}' /proc/meminfo)"
else
  warn "DRY RUN: системные проверки и установка пропущены"
fi

# ───────────────────────── интерактивный опросник ─────────────────────────
interactive=0
[[ -t 0 ]] && interactive=1

need_input=0
[[ -z "$FQDN" || -z "$EMAIL" ]] && need_input=1
if [[ $need_input -eq 1 && $interactive -eq 0 ]]; then
  die "Нет терминала для вопросов. Передайте параметры флагами:
     sudo bash install.sh --hostname proxy.example.com --email you@example.com --yes"
fi

# prompt_value ИМЯ_ПЕРЕМЕННОЙ "вопрос" "значение_по_умолчанию" "регексп" "текст_ошибки"
prompt_value() {
  local var="$1" question="$2" default="${3:-}" re="${4:-.}" errmsg="${5:-Неверное значение}"
  local current="${!var}" input=""
  if [[ -n "$current" ]]; then
    [[ "$current" =~ $re ]] || die "$errmsg (получено: $current)"
    return 0
  fi
  while true; do
    if [[ -n "$default" ]]; then
      printf '  %s\n  %s[%s]%s > ' "$question" "$DIM" "$default" "$OFF"
    else
      printf '  %s\n  > ' "$question"
    fi
    IFS= read -r input || die "Ввод прерван."
    [[ -z "$input" && -n "$default" ]] && input="$default"
    if [[ "$input" =~ $re ]]; then
      printf -v "$var" '%s' "$input"
      printf '\n'
      return 0
    fi
    printf '  %s%s%s\n\n' "$RED" "$errmsg" "$OFF"
  done
}

step "Параметры установки"

prompt_value FQDN \
  "Домен прокси (A-запись должна вести на этот сервер, без https:// и без порта):" \
  "" '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
  "Нужен домен в нижнем регистре минимум с одной точкой, например proxy.example.com"

prompt_value EMAIL \
  "Email для Let's Encrypt (на него придут уведомления об истечении сертификата):" \
  "" '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' \
  "Похоже, это не email"

default_project="$(printf '%s' "${FQDN%%.*}" | sed 's/^./\U&/')"
prompt_value PROJECT \
  "Название проекта для сайта-прикрытия (то, что увидит посетитель домена):" \
  "$default_project" '^[[:print:]]{2,40}$' \
  "От 2 до 40 печатных символов"

# секрет
if [[ -n "$SECRET" ]]; then
  [[ "$SECRET" =~ ^(dd)?[0-9a-f]{32}$ ]] || die "Секрет — 32 hex-символа в нижнем регистре (можно с префиксом dd)."
  info "Секрет взят из --secret"
elif [[ -s "$SECRET_FILE" ]]; then
  SECRET="$(tr -d '[:space:]' < "$SECRET_FILE")"
  [[ "$SECRET" =~ ^(dd)?[0-9a-f]{32}$ ]] || die "В $SECRET_FILE лежит не 32 hex-символа.
     Задайте секрет явно (--secret HEX) или удалите файл, чтобы сгенерировать новый."
  info "Найден сохранённый секрет в $SECRET_FILE — переиспользую (ссылка не изменится)"
else
  SECRET="$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  info "Сгенерирован новый случайный секрет"
fi

# воркеры
if [[ -z "$WORKERS" ]]; then
  cores="$(nproc 2>/dev/null || echo 1)"
  WORKERS=$(( cores > 4 ? 4 : cores ))
fi
[[ "$WORKERS" =~ ^[0-9]+$ ]] && (( WORKERS >= 1 && WORKERS <= 256 )) \
  || die "--workers должно быть числом от 1 до 256."

# ──────────────────────────── подтверждение ──────────────────────────────
step "Проверьте параметры"
printf '  домен          : %s%s%s\n' "$CYAN" "$FQDN" "$OFF"
printf '  email (ACME)   : %s\n' "$EMAIL"
printf '  проект на сайте: %s\n' "$PROJECT"
printf '  секрет         : %s\n' "$SECRET"
printf '  MTProxy воркеры: %s\n' "$WORKERS"
printf '\n  Будет установлено: Caddy (TLS), tproxy-server (relay), MTProxy.\n'
printf '  Наружу слушает только Caddy на портах 80 и 443.\n'

if [[ $ASSUME_YES -eq 0 ]]; then
  [[ $interactive -eq 1 ]] || die "Нет терминала для подтверждения — добавьте --yes."
  printf '\n  Продолжить? [y/N] > '
  IFS= read -r answer || true
  case "${answer:-}" in
    [yYдД]|[yY]es|да) : ;;
    *) printf '\n  Отменено.\n\n'; exit 0 ;;
  esac
fi

# ─────────────────────────────── зависимости ──────────────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
  step "Установка зависимостей"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq git curl ca-certificates openssl dnsutils iproute2 python3 >/dev/null
  ok "git, curl, openssl, dig, ss, python3"
fi

# ────────────────────────────── проверка DNS ──────────────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
  step "Проверка A-записи"
  if [[ $SKIP_DNS -eq 1 ]]; then
    warn "Проверка пропущена (--skip-dns-check)"
  else
    myip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo '')"
    resolved="$(dig +short A "$FQDN" @1.1.1.1 2>/dev/null | tail -n1 || true)"
    if [[ -z "$resolved" ]]; then
      die "A-запись для $FQDN не найдена.
     Создайте у DNS-провайдера запись A на IP этого сервера${myip:+ ($myip)},
     дождитесь распространения и запустите скрипт снова.
     Обойти проверку: --skip-dns-check"
    fi
    ok "$FQDN -> $resolved"
    if [[ -n "$myip" && "$resolved" != "$myip" ]]; then
      warn "Внешний IP сервера $myip не совпадает с A-записью $resolved."
      warn "Если домен за Cloudflare — ОТКЛЮЧИТЕ проксирование (серая тучка, DNS only):"
      warn "через оранжевую тучку WEB-прокси не работает, Cloudflare терминирует TLS."
      if [[ $ASSUME_YES -eq 0 && $interactive -eq 1 ]]; then
        printf '\n  Всё равно продолжить? [y/N] > '
        IFS= read -r a2 || true
        case "${a2:-}" in [yYдД]|[yY]es|да) : ;; *) die "Остановлено на проверке DNS." ;; esac
      fi
    fi
  fi

  step "Проверка портов 80 и 443"
  for p in 80 443; do
    if ss -lnt "sport = :$p" 2>/dev/null | grep -q LISTEN; then
      holder="$(ss -lntp "sport = :$p" 2>/dev/null | awk 'NR==2{print $NF}')"
      die "Порт $p занят: ${holder:-неизвестно}
     Наружу должен слушать только Caddy. Например: systemctl disable --now nginx"
    fi
  done
  ok "80 и 443 свободны"

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ok "ufw активен — 80/tcp и 443/tcp разрешены"
  fi
fi

# ───────────────────────── исходники tproxy-server ───────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
  step "Получение tproxy-server"
  if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" fetch --depth 1 origin >/dev/null 2>&1 || true
    git -C "$SRC_DIR" reset --hard FETCH_HEAD >/dev/null 2>&1 || true
    ok "Обновлён: $SRC_DIR"
  else
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$UPSTREAM_REPO" "$SRC_DIR" >/dev/null 2>&1 \
      || die "Не удалось склонировать $UPSTREAM_REPO — проверьте выход в интернет."
    ok "Склонирован в $SRC_DIR"
  fi
  [[ -x "$SRC_DIR/deploy/install.sh" ]] || chmod +x "$SRC_DIR/deploy/install.sh" 2>/dev/null || true
  [[ -f "$SRC_DIR/deploy/install.sh" ]] || die "В tproxy-server нет deploy/install.sh — структура изменилась, см. его README."

  # ── Обход бага апстрима ─────────────────────────────────────────────────
  # deploy/install.sh в строке 3 выставляет umask 077 и с этим umask запускает
  # `go test ./...`. Тест TestLoadAcceptsSystemdCredentialReadPermissions
  # создаёт фикстуру через os.WriteFile(..., 0444); под umask 077 она получает
  # права 0400, проверка «profiles_file не должен быть доступен группе и
  # остальным» не срабатывает — и негативная часть теста падает:
  #   config_test.go:248: group/other-readable profiles file ... was accepted
  # Из-за set -e установка обрывается до сборки. Возвращаем тестам обычный
  # umask — остальные тесты при этом продолжают выполняться.
  upstream_installer="$SRC_DIR/deploy/install.sh"
  if [[ "${TGWEB_SKIP_UPSTREAM_TESTS:-0}" == "1" ]]; then
    sed -i 's|^(cd "$repository" && \(umask 022 && \)\?"$go_binary" test \./\.\.\.)|# отключено TGWEB_SKIP_UPSTREAM_TESTS: \0|' \
      "$upstream_installer"
    warn "Тесты апстрима отключены (TGWEB_SKIP_UPSTREAM_TESTS=1)"
  elif grep -q 'umask 022 && "$go_binary" test' "$upstream_installer"; then
    info "Патч umask для go test уже применён"
  elif grep -q '"$go_binary" test \./\.\.\.' "$upstream_installer"; then
    sed -i 's|"$go_binary" test \./\.\.\.|umask 022 \&\& "$go_binary" test ./...|' "$upstream_installer"
    ok "Патч: go test запускается с umask 022 (обход бага апстрима)"
  else
    warn "Строка с go test в апстриме не найдена — вероятно, баг уже исправлен."
  fi

  # ── Второй симптом того же umask 077 ────────────────────────────────────
  # deploy/install-mtproxy.sh собирает MTProxy под тем же umask 077, поэтому
  # objs/, objs/bin/ и сам бинарник создаются с правами 0700, а затем
  # выполняется chown -R root:root. Сервис запускается под User=mtproxy и не
  # может ни войти в каталог, ни выполнить файл — systemd отдаёт 203/EXEC и
  # уходит в рестарт-луп. Проверка `test -x` в апстриме этого не ловит, она
  # выполняется от root. Добавляем chmod перед chown.
  mtproxy_installer="$SRC_DIR/deploy/install-mtproxy.sh"
  if [[ -f "$mtproxy_installer" ]]; then
    if grep -q 'chmod -R a+rX "$build_directory"' "$mtproxy_installer"; then
      info "Патч прав MTProxy уже применён"
    elif grep -q 'chown -R root:root "$build_directory"' "$mtproxy_installer"; then
      sed -i 's|chown -R root:root "$build_directory"|chmod -R a+rX "$build_directory"\n\tchown -R root:root "$build_directory"|' \
        "$mtproxy_installer"
      ok "Патч: сборка MTProxy получает права, читаемые пользователем mtproxy"
    else
      warn "Строка chown в install-mtproxy.sh не найдена — вероятно, баг уже исправлен."
    fi
  fi

  # Уже собранное дерево от предыдущего (сломанного) запуска тоже починим:
  # апстрим не пересобирает MTProxy, если бинарник на месте, поэтому права
  # 0700 остались бы навсегда.
  if [[ -x /opt/MTProxy/objs/bin/mtproto-proxy ]]; then
    chmod -R a+rX /opt/MTProxy
    ok "Права на уже собранный /opt/MTProxy приведены в порядок"
  fi
fi

# ───────────────────────── сборка сайта-прикрытия ────────────────────────
step "Сборка сайта-прикрытия"
[[ "$DRY_RUN" == "1" ]] && BUILD_DIR="/tmp/tgweb-site-dryrun"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cp -a "$SITE_SRC/." "$BUILD_DIR/"

rand_hex() { openssl rand -hex "${1:-4}" 2>/dev/null || head -c "${1:-4}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
pick() { local -n arr="$1"; printf '%s' "${arr[RANDOM % ${#arr[@]}]}"; }

# Каждая установка получает свой набор мелочей, чтобы страницы не были
# байт-в-байт одинаковыми у всех, кто поставил этот репозиторий.
# Массивы ниже читаются через nameref в pick(), поэтому shellcheck их не видит.
# shellcheck disable=SC2034
ACCENTS=("#5b9cff" "#7a8cff" "#4ea8de" "#5fb3a3" "#c98bdb" "#e08a5a" "#61b0f0" "#8fbf6a")
# shellcheck disable=SC2034
H1S=(
  "A small video pipeline you can actually host yourself."
  "Video ingest, transcode and delivery on one box."
  "Self-hosted video, without the per-minute bill."
  "One binary between your upload and an HLS playlist."
)
# shellcheck disable=SC2034
LEADS=(
  "takes an upload, normalises it, transcodes to an adaptive HLS ladder and serves the segments over HTTP. One binary, one config file, no queue broker, no object storage requirement."
  "probes what you give it, builds an adaptive HLS ladder with ffmpeg and serves the segments straight off local disk. No broker, no bucket, no control plane."
  "is a single process that watches a directory, transcodes what appears there and publishes an HLS playlist. That is the whole feature set."
)
# shellcheck disable=SC2034
WHYS=(
  "Every hosted transcoder I tried billed per minute of output and wanted my media in their bucket. For a personal archive of a few hundred hours that is absurd."
  "I wanted to re-encode an old camcorder archive without uploading it to anyone. Turns out the hard part is not the transcoding, it is all the platform around it."
  "This started as a shell script with a cron entry. It grew a state machine and an HTTP API because resuming a failed batch by hand got old."
)

ACCENT="$(pick ACCENTS)"
H1="$(pick H1S)"
LEAD="$(pick LEADS)"
WHY="$(pick WHYS)"
BUILD_ID="$(rand_hex 4)"
ASSET1="as_$(rand_hex 4)"
ASSET2="as_$(rand_hex 4)"
DURATION="$(( (RANDOM % 900 + 120) * 1000 + RANDOM % 999 ))"
PROJECT_LC="$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]')"
YEAR="$(date +%Y)"

subst() {
  local f="$1"
  python3 - "$f" <<'PY'
import os, sys
path = sys.argv[1]
keys = ["HOST","EMAIL","PROJECT","PROJECT_LC","ACCENT","H1","LEAD","WHY",
        "BUILD","ASSET1","ASSET2","DURATION","YEAR"]
with open(path, encoding="utf-8") as fh:
    data = fh.read()
for k in keys:
    data = data.replace("__%s__" % k, os.environ.get("TGW_" + k, ""))
with open(path, "w", encoding="utf-8") as fh:
    fh.write(data)
PY
}

export TGW_HOST="$FQDN" TGW_EMAIL="$EMAIL" TGW_PROJECT="$PROJECT" \
       TGW_PROJECT_LC="$PROJECT_LC" TGW_ACCENT="$ACCENT" TGW_H1="$H1" \
       TGW_LEAD="$LEAD" TGW_WHY="$WHY" TGW_BUILD="$BUILD_ID" \
       TGW_ASSET1="$ASSET1" TGW_ASSET2="$ASSET2" TGW_DURATION="$DURATION" \
       TGW_YEAR="$YEAR"

if ! command -v python3 >/dev/null; then
  die "Нужен python3 для подстановки значений в шаблоны сайта (apt-get install -y python3)."
fi
while IFS= read -r -d '' f; do subst "$f"; done \
  < <(find "$BUILD_DIR" -type f \( -name '*.html' -o -name '*.css' -o -name '*.txt' \) -print0)

if grep -rq '__[A-Z_]\{2,\}__' "$BUILD_DIR" 2>/dev/null; then
  warn "В сайте остались незаполненные заглушки:"
  grep -rho '__[A-Z_]\{2,\}__' "$BUILD_DIR" | sort -u | sed 's/^/         /'
fi

chmod -R a+rX "$BUILD_DIR"
ok "Собрано файлов: $(find "$BUILD_DIR" -type f | wc -l), акцент $ACCENT, build $BUILD_ID"

if [[ "$DRY_RUN" == "1" ]]; then
  printf '\n  DRY RUN завершён. Сайт собран в %s\n\n' "$BUILD_DIR"
  exit 0
fi

# ────────────────────────── сохранение состояния ─────────────────────────
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
umask 077
printf '%s\n' "$SECRET" > "$SECRET_FILE"; chmod 400 "$SECRET_FILE"
umask 022

# ─────────────────────── запуск установщика upstream ─────────────────────
step "Установка Caddy + relay + MTProxy"
info "Это займёт несколько минут: сборка MTProxy и выпуск сертификата."
cd "$SRC_DIR"
./deploy/install.sh \
  --hostname "$FQDN" \
  --email "$EMAIL" \
  --site-dir "$BUILD_DIR" \
  --secret "$SECRET" \
  --mtproxy-workers "$WORKERS" \
  --mtproxy-max-connections 4096

# ──────────────────────────── пост-проверки ──────────────────────────────
step "Проверка сервисов"
sleep 5
failed=0
for svc in caddy tproxy-server mtproxy; do
  if systemctl is-active --quiet "$svc"; then
    ok "$svc: active"
  else
    warn "$svc НЕ активен — journalctl -u $svc -n 50 --no-pager"
    failed=1
  fi
done

step "Локальные health-эндпоинты"
curl -fsS --max-time 5 http://127.0.0.1:8081/healthz >/dev/null 2>&1 \
  && ok "/healthz отвечает" || { warn "/healthz недоступен"; failed=1; }
if curl -fsS --max-time 8 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
  ok "/readyz готов — бэкенд MTProxy на месте"
else
  warn "/readyz не готов: systemctl status mtproxy; ss -lntp | grep 2398"
  failed=1
fi

step "Проверка сайта снаружи"
code="000"
for i in 1 2 3 4 5 6; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "https://$FQDN/" 2>/dev/null || true)"
  [[ -n "$code" ]] || code="000"
  [[ "$code" == "200" ]] && break
  info "попытка $i/6: код $code, ждём выпуск сертификата..."
  sleep 10
done
if [[ "$code" == "200" ]]; then
  ok "https://$FQDN/ отдаёт 200 — прикрытие работает"
else
  warn "https://$FQDN/ вернул $code. ACME может занять пару минут."
  warn "Смотрите: journalctl -u caddy -n 60 --no-pager"
fi

# ─────────────────────────────── итог ────────────────────────────────────
LINK="https://t.me/webproxy?server=$FQDN&secret=$SECRET"
{
  printf 'TGweb %s — установлено %s\n\n' "$VERSION" "$(date -Is)"
  printf 'Тип прокси : WEB\nHostname   : %s\nSecret     : %s\n\n' "$FQDN" "$SECRET"
  printf 'Ссылка     : %s\n' "$LINK"
  printf 'tg://      : tg://webproxy?server=%s&secret=%s\n\n' "$FQDN" "$SECRET"
  printf 'Сайт (сборка) : %s\nСайт (рабочий): /srv/tproxy-site\n' "$BUILD_DIR"
  printf 'Конфиг relay  : /etc/tproxy-server/config.json\n'
  printf 'Профили       : /etc/tproxy-server/profiles.json\n'
} > "$INFO_FILE"
chmod 600 "$INFO_FILE"

cat <<EOF

${BOLD}──────────────────────────────── готово ────────────────────────────────${OFF}

  В Telegram выберите тип прокси ${BOLD}WEB${OFF} и введите:

    Hostname : ${CYAN}$FQDN${OFF}
    Secret   : ${CYAN}$SECRET${OFF}

  Или откройте ссылку:

    ${GREEN}$LINK${OFF}

  Работает в Telegram Desktop 7.1.1+. На Android — прототип, iOS в планах.

  Реквизиты сохранены в $INFO_FILE (chmod 600).

  Управление:
    bash status.sh                       состояние и ссылка
    systemctl status tproxy-server caddy mtproxy
    journalctl -u tproxy-server -f
    curl -s http://127.0.0.1:8081/metrics
    cd $SRC_DIR && sudo ./deploy/update-relay.sh

${YELLOW}  Важно:${OFF} отредактируйте тексты в site/ под себя и запустите install.sh
  заново. Одинаковый сайт у многих операторов сам становится сигнатурой
  для активного зондирования — это прямая рекомендация авторов tproxy-server.

EOF

exit "$failed"
