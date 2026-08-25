# TGweb

Интерактивная установка **Telegram WEB-прокси** на свой VPS — вместе с сайтом-прикрытием,
который делает домен похожим на обычный веб-проект.

Обёртка над официальным [telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server):
скрипт спрашивает домен, email и название проекта, проверяет окружение, собирает сайт,
запускает установщик и печатает готовую ссылку для Telegram.

---

## Что такое WEB-прокси

Новый тип прокси, появившийся в Telegram Desktop 7.1.1 (август 2026). В отличие от MTProto,
где DPI видит «странный» TCP-поток на нестандартный порт, здесь весь трафик MTProxy
заворачивается в **обычный HTTPS/WebSocket к обычному домену на 443 порт**. Для провайдера это
выглядит как посещение сайта.

Как это работает:

1. Клиент устанавливает MTProxy-соединение по обычным правилам — шифрование не меняется.
2. Готовый зашифрованный поток отдаётся локальному WEB-адаптеру внутри Telegram.
3. Адаптер поднимает **WebView** с bridge-страницей на вашем домене и гонит данные через неё.
4. Свой мультиплекс-протокол (кадры `OPEN` / `DATA` / `WINDOW` / `CLOSE` / `PING`-`PONG` /
   `HELLO`-`WELCOME`) укладывает несколько логических соединений в один веб-канал.
5. На сервере relay распаковывает и отдаёт в локальный MTProxy на `127.0.0.1:2398`.

Сервер **не может** расшифровать ваш трафик — он только транспорт, и не работает как открытый
прокси на произвольные адреса.

---

## Требования

| Что | Подробности |
|---|---|
| Сервер | x86_64, Ubuntu 22.04+ или Debian 12+, публичный IPv4, systemd, root |
| Домен | отдельный субдомен в нижнем регистре, A-запись напрямую на IP сервера |
| Порты | входящие TCP 80 и 443 свободны и открыты |
| Ресурсы | 1 vCPU / 1 GB RAM хватает для личного использования |

> **Cloudflare:** проксирование (оранжевая тучка) должно быть **отключено** — только DNS only.
> Cloudflare терминирует TLS и разорвёт транспорт, плюс Let's Encrypt не сможет выпустить
> сертификат напрямую. Скрипт предупредит, если увидит несовпадение IP.

---

## Установка

На минимальных образах Debian/Ubuntu `git` не предустановлен — поставьте его первым:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/SkunkBG/TGweb.git
cd TGweb
sudo bash install.sh
```

Без git — архивом:

```bash
apt-get update && apt-get install -y curl unzip
curl -fsSL -o tgweb.zip https://github.com/SkunkBG/TGweb/archive/refs/heads/main.zip
unzip -q tgweb.zip && cd TGweb-main
bash install.sh
```

Скрипт задаст четыре вопроса:

```
Домен прокси (A-запись должна вести на этот сервер):
> proxy.example.com

Email для Let's Encrypt:
> you@example.com

Название проекта для сайта-прикрытия:
[Proxy] > Soul

Продолжить? [y/N] > y
```

Секрет генерируется автоматически (`openssl rand -hex 16`) и сохраняется в
`/etc/tgweb/secret` с правами 400. При повторном запуске он переиспользуется — ссылка
на прокси не меняется.

### Неинтерактивно

```bash
sudo bash install.sh \
  --hostname proxy.example.com \
  --email you@example.com \
  --project Soul \
  --yes
```

Все опции:

| Опция | Назначение |
|---|---|
| `--hostname FQDN` | домен прокси |
| `--email ADDR` | контакт для Let's Encrypt |
| `--project NAME` | название проекта на сайте-прикрытии |
| `--secret HEX` | свой секрет, 32 hex-символа (по умолчанию случайный) |
| `--workers N` | воркеров MTProxy (по умолчанию по числу ядер, максимум 4) |
| `--skip-dns-check` | не сверять A-запись |
| `-y`, `--yes` | без подтверждений |

### Проверить сборку сайта, ничего не устанавливая

```bash
TGWEB_DRY_RUN=1 bash install.sh --hostname test.example.com --email a@b.c --project Demo --yes
```

Соберёт сайт в `/tmp/tgweb-site-dryrun` и выйдет. Можно посмотреть глазами:
`cd /tmp/tgweb-site-dryrun && python3 -m http.server 8000`.

---

## Подключение в Telegram

После установки скрипт напечатает:

```
Hostname : proxy.example.com
Secret   : 000102030405060708090a0b0c0d0e0f

https://t.me/webproxy?server=proxy.example.com&secret=000102030405060708090a0b0c0d0e0f
```

В настройках Telegram выберите тип прокси **WEB** и введите hostname и secret. Хост — без
`https://`, без порта и без пути: HTTPS и 443 у этого типа зафиксированы.

Ссылку можно посмотреть позже:

```bash
sudo bash status.sh
```

**Клиенты:** Telegram Desktop 7.1.1+ работает, на Android прототип, iOS в планах.
Если `t.me/webproxy` не открывается — введите значения руками в настройках.

---

## Сайт-прикрытие

В `site/` лежит шаблон: лендинг, API-документация, changelog, статус, privacy, 404.
Легенда — небольшой self-hosted видео-пайплайн (ingest → transcode → HLS delivery).

Почему именно такая:

- **Объясняет трафик.** Отдача видео-сегментов делает естественными и большой объём,
  и долгие соединения, и рваные чанки — то самое, что генерирует WEB-прокси.
- **Личный проект не обязан иметь посетителей.** «Сервис» без живых пользователей выглядит
  странно, хобби-проект с одним пользователем — нормально.
- **Ничего лишнего.** Нет форм входа, нет платежей, нет чужого брендинга.
- **Полностью автономна.** Ни CDN, ни внешних шрифтов, ни аналитики — системные шрифты и
  один локальный CSS. Нечему утекать и нечему отваливаться.

Установщик подставляет в шаблоны домен, email, название проекта, а также **случайные** акцентный
цвет, build-id, идентификаторы примеров и вариант заголовка — чтобы страницы у разных
пользователей этого репозитория не были байт-в-байт одинаковыми.

### Обязательно перепишите тексты

Авторы `tproxy-server` пишут прямо:

> The repository deliberately does not include a deployable public website. If many operators
> installed the same starter, its body and assets would become an easy active-probing signature.

Случайных мелочей мало. Отредактируйте `site/*.html` под себя — заголовки, названия
эндпоинтов, «known issues», добавьте пару своих страниц — и запустите `install.sh` заново.
Чем меньше сайт похож на шаблон из репозитория, тем лучше.

Доступные подстановки в шаблонах:

| Заглушка | Значение |
|---|---|
| `__HOST__` | домен |
| `__PROJECT__` / `__PROJECT_LC__` | название проекта / в нижнем регистре |
| `__EMAIL__` | email |
| `__ACCENT__` | случайный акцентный цвет |
| `__H1__` / `__LEAD__` / `__WHY__` | случайный вариант текста |
| `__BUILD__` | случайный build-id |
| `__ASSET1__` / `__ASSET2__` / `__DURATION__` | случайные значения в примерах |
| `__YEAR__` | текущий год |

Единственный обязательный файл — `index.html`.

---

## Что и куда ставится

Наружу слушает **только Caddy**. Relay, MTProxy и админка — на loopback.

```
Telegram → WEB-адаптер → WebView → Caddy :443 → relay → MTProxy 127.0.0.1:2398
```

| Путь | Что |
|---|---|
| `/opt/tproxy-src` | исходники tproxy-server |
| `/opt/tgweb-site` | собранный сайт (источник для установщика) |
| `/srv/tproxy-site` | рабочая копия сайта |
| `/etc/tproxy-server/config.json` | конфиг relay |
| `/etc/tproxy-server/profiles.json` | профили и секреты, chmod 400 |
| `/etc/mtproxy/mtproxy.env` | окружение MTProxy |
| `/etc/caddy/Caddyfile*` | конфиг Caddy |
| `/etc/tgweb/secret` | секрет, chmod 400 |
| `/etc/tgweb/info.txt` | реквизиты подключения, chmod 600 |

Сервисы: `caddy`, `tproxy-server`, `mtproxy`, `tproxy-firewall`, `refresh-mtproxy-config`.

---

## Эксплуатация

```bash
sudo bash status.sh                       # сервисы, health, метрики, ссылка
sudo bash harden.sh                       # файрвол, fail2ban, тюнинг
systemctl status tproxy-server caddy mtproxy
journalctl -u tproxy-server -f
curl -s http://127.0.0.1:8081/metrics     # только с самого сервера

cd /opt/tproxy-src && sudo ./deploy/update-relay.sh   # обновить relay
```

Loopback-эндпоинты: `/healthz` (живость), `/readyz` (готовность вместе с бэкендом),
`/metrics` (счётчики) на `127.0.0.1:8081`.

### Несколько пользователей

Каждому — свой секрет отдельным профилем в `/etc/tproxy-server/profiles.json`:

```json
{
  "profiles": [
    { "name": "alpha", "secret": "0123456789abcdef0123456789abcdef",
      "backend": "127.0.0.1:2398", "carrier_mode": "https" }
  ]
}
```

`carrier_mode`: `https`, `https-lanes`, `websocket`, `websocket-lanes`. Файл должен быть 0400.
После правки — `systemctl restart tproxy-server`.

### Удаление

```bash
sudo bash uninstall.sh
```

---

## Защита и настройка сервера

После установки прокси снаружи открыт весь диапазон портов, кроме 2398 и 8888 — их
закрывает `tproxy-firewall` от установщика. Всё остальное, включая SSH, доступно любому.
`harden.sh` приводит это в порядок:

```bash
sudo bash harden.sh
```

Проверено на Debian 12 (bookworm) и 13 (trixie), работает и на Ubuntu 22.04+.
Каждый блок можно отключить: `--skip-firewall`, `--skip-fail2ban`, `--skip-tuning`,
`--skip-extras`. Без вопросов — `-y`.

### 1. Файрвол (ufw)

Входящие запрещены по умолчанию, исходящие разрешены, открыты только SSH (с
ограничением частоты через `ufw limit`), 80 и 443.

Порт SSH **определяется автоматически** через `sshd -T` — это учитывает `Include` и
`Match`, в отличие от чтения `sshd_config` глазами. Дополнительно скрипт берёт порт из
`SSH_CONNECTION` текущей сессии и добавляет его принудительно, даже если в конфиге его не
нашлось. После применения правил он отдельно проверяет, что порт действительно виден в
`ufw status`, и предупреждает, если нет. Это защита от самого дорогого сценария —
запереть себя снаружи.

ufw и `tproxy_backend` не конфликтуют: это разные таблицы nftables на разных хуках, и
пакет обязан пройти обе. Правила прокси остаются в силе.

### 2. fail2ban

Здесь есть неочевидная ловушка. Штатный jail `sshd` читает `/var/log/auth.log`
(`sshd_log = %(syslog_authpriv)s` в `paths-common.conf`), но на Debian 13 rsyslog не
устанавливается по умолчанию, а на минимальных образах Debian 12 и свежих Ubuntu его тоже
обычно нет. Файла не существует, jail молча не стартует — и человек считает, что защищён,
хотя перебор паролей идёт свободно.

Поэтому `harden.sh` пишет `backend = systemd`, то есть читает journald напрямую. У этого
своё условие: нужен рабочий `python3-systemd`. Скрипт **проверяет импорт** до записи
конфига, и если он не работает, откатывается на файловый backend с явным `logpath`, а если
и `auth.log` нет — говорит об этом прямо, вместо тихого отказа.

Получается такой `/etc/fail2ban/jail.local`:

```ini
[DEFAULT]
backend   = systemd
banaction = ufw               # nftables-multiport, если ufw неактивен
bantime   = 1h
findtime  = 10m
maxretry  = 5
bantime.increment = true      # повторные визиты — бан вдвое дольше, до недели
bantime.factor    = 2
bantime.maxtime   = 1w
ignoreip  = 127.0.0.1/8 ::1 <ваш IP из SSH_CONNECTION>

[sshd]
enabled = true
port    = <определённые порты>
```

Ваш текущий IP попадает в `ignoreip` автоматически. Прежний `jail.local`, если он был,
сохраняется рядом с суффиксом `.bak.<дата>`. Конфиг проверяется через `fail2ban-client -t`
**до** перезапуска сервиса — при ошибке скрипт не трогает работающий fail2ban.

Версии: Debian 12 — fail2ban 1.0.2, Debian 13 — 1.1.0. Обе поддерживают
`backend = systemd`, `banaction = ufw` и `bantime.increment`, конфиг одинаковый.

Полезное:

```bash
fail2ban-client status sshd
fail2ban-client set sshd unbanip 203.0.113.10
```

Отдельно: fail2ban не заменяет ключи. Вход по паролю с работающими ключами — это лишний
риск, и скрипт про это скажет, но сам пароли **не отключает** — иначе можно отрезать себе
доступ. Делается вручную, обязательно с проверкой во втором окне:

```bash
echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/99-no-password.conf
sshd -t && systemctl reload ssh
```

### 3. Сетевой тюнинг

Пишется в `/etc/sysctl.d/99-tgweb.conf`. Смысл каждой группы:

| Параметр | Зачем |
|---|---|
| `default_qdisc = fq`, `tcp_congestion_control = bbr` | BBR ровнее CUBIC на длинных маршрутах с потерями, а трафик через прокси идёт именно такими. Включается только если ядро реально умеет BBR — скрипт проверяет `tcp_available_congestion_control` |
| `somaxconn`, `netdev_max_backlog`, `tcp_max_syn_backlog` | Одно ядро и много коротких соединений от carrier-сессий |
| `ip_local_port_range`, `tcp_tw_reuse`, `tcp_fin_timeout` | MTProxy держит исходящие к дата-центрам Telegram; шире диапазон и быстрее переиспользование |
| `tcp_mtu_probing`, `tcp_slow_start_after_idle = 0`, `tcp_keepalive_*` | Живучесть долгих HTTPS/WebSocket-сессий и обход чёрных дыр MTU |
| `fs.file-max` | Юниты просят `LimitNOFILE=1048576` |
| `vm.swappiness = 10` | Своп как страховка, а не как рабочий режим |

Если ядро часть значений не примет (бывает в контейнерах и на OpenVZ), скрипт не падает —
предупреждает и показывает, что фактически применилось.

### 4. Своп, журнал, автообновления

**Своп** создаётся только если его нет, RAM меньше 2 ГБ и на `/` есть хотя бы 3 ГБ
свободных — 1 ГБ файлом, с записью в `fstab`. На вашей конфигурации (960 МБ RAM) это
осмысленно: MTProxy, Go-relay и Caddy на одном гигабайте живут впритык.

**journald** по умолчанию может занять до 10% раздела. Ограничивается 200 МБ через
`/etc/systemd/journald.conf.d/99-tgweb.conf` — на маленьком VPS переполнение диска
реальный сценарий.

**unattended-upgrades** ставятся с подтверждением. Обновления ядра применяются, но
перезагрузку нужно делать руками.

---

## Известные проблемы апстрима

### `go test` падает на `TestLoadAcceptsSystemdCredentialReadPermissions`

```
--- FAIL: TestLoadAcceptsSystemdCredentialReadPermissions (0.00s)
    config_test.go:248: group/other-readable profiles file outside a credential
                        directory was accepted
```

Установка обрывается до сборки бинарника. Это баг в самом `tproxy-server`, а не в
вашей конфигурации, и он воспроизводится на любой чистой машине.

Причина: `deploy/install.sh` в строке 3 выставляет `umask 077` и с этим umask запускает
`go test ./...`. Тест создаёт фикстуру через `os.WriteFile(..., 0444)`, но под `umask 077`
файл получает права `0400`. Проверка в `loadProfiles()` считает лишние биты как
`mode & 0077`; для `0400` это ноль, ошибка не возвращается — и негативная часть теста,
ожидающая отказа, падает. С обычным `umask 022` файл создаётся как `0444`, проверка
срабатывает, тест проходит.

`install.sh` из этого репозитория **исправляет это автоматически** сразу после
клонирования: строка с тестами получает префикс `umask 022 &&`. Остальные тесты при этом
продолжают выполняться — набор не отключается.

Если понадобится пропустить тесты апстрима целиком (крайний случай):

```bash
TGWEB_SKIP_UPSTREAM_TESTS=1 bash install.sh
```

Когда апстрим починит это у себя, патч сам перестанет применяться — скрипт проверяет
наличие строки перед правкой.

### `mtproxy.service` падает с `status=203/EXEC` в рестарт-луп

```
mtproxy.service: Main process exited, code=exited, status=203/EXEC
mtproxy.service: Scheduled restart job, restart counter is at 44.
```

`readyz` при этом навсегда остаётся `503`, а установка обрывается на
`tproxy-server did not become ready`. Это второй симптом того же `umask 077`.

`deploy/install-mtproxy.sh` собирает MTProxy под этим umask, поэтому `objs/`,
`objs/bin/` и сам `mtproto-proxy` создаются с правами `0700`, после чего выполняется
`chown -R root:root`. Юнит запускается под `User=mtproxy` — и этот пользователь не может
ни войти в каталог, ни выполнить файл. Апстримовая проверка `test -x` этого не замечает,
потому что выполняется от root, а для root достаточно любого бита `x`.

`install.sh` из этого репозитория добавляет `chmod -R a+rX` перед `chown` (для свежих
сборок) и приводит в порядок права уже собранного `/opt/MTProxy` (апстрим не пересобирает
MTProxy, если бинарник на месте, поэтому иначе права `0700` остались бы навсегда).

Починить вручную на уже сломанной установке:

```bash
namei -l /opt/MTProxy/objs/bin/mtproto-proxy      # увидите drwx------
chmod -R a+rX /opt/MTProxy
systemctl reset-failed mtproxy && systemctl restart mtproxy
curl -s -o /dev/null -w 'readyz=%{http_code}\n' http://127.0.0.1:8081/readyz
```

---

## Диагностика

| Симптом | Куда смотреть |
|---|---|
| Сертификат не выпускается | A-запись ведёт напрямую на сервер? Cloudflare в DNS only? 80 и 443 доходят до Caddy? `journalctl -u caddy -n 60` |
| `/readyz` отдаёт 503 | `systemctl status mtproxy`, `ss -lntp \| grep 2398` |
| В WebView открывается публичный сайт | hostname и secret в клиенте не совпадают с профилем на сервере |
| Порт 80 или 443 занят | остановите свой веб-сервер: `systemctl disable --now nginx` |
| Permission denied на профилях | `chmod 400 /etc/tproxy-server/profiles.json` |
| Забанил себя в fail2ban | С другого IP: `fail2ban-client set sshd unbanip <ваш IP>`, либо через консоль хостера |
| Jail sshd не стартует | `python3 -c 'from systemd import journal'` — если падает, `apt-get install --reinstall python3-systemd` |

---

## Безопасность

- **Секрет в списке процессов.** `install.sh` передаёт `--secret` флагом, чтобы установка
  прошла без лишних вопросов. Upstream предупреждает, что это «places the value in the invoking
  process list». На одиночном VPS это приемлемо; если нужно строже — уберите строку
  `--secret "$SECRET"` из вызова, и установщик спросит секрет интерактивно без эха.
- **Чужим WEB-прокси доверять не стоит.** Telegram Desktop 7.1.2 показывает предупреждение:
  *«this web proxy runs a web page from its provider in the background while you're connected»*.
  Владелец прокси крутит у вас в фоне свой код. Свой сервер решает эту проблему.
- **Bridge-страница сильно ограничена** самим Telegram: запрещены cookies, localStorage,
  IndexedDB, Service Workers, камера/микрофон и внешние ресурсы; разрешены только inline-скрипты
  и соединения к своему же домену.
- **Не выносите сайт из-под relay.** Relay должен остаться единственным публичным входом на
  этом домене, иначе заголовки и тайминги выдадут отдельную транспортную поверхность.

---

## Статус

`tproxy-server` — proof-of-concept от авторов Telegram Desktop. Протокол и раскладка на диске
могут меняться. Этот репозиторий — обёртка вокруг него, а не форк: сам relay всегда берётся
свежим из upstream при установке.

## Ссылки

- [telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server) — официальный сервер
- [Telegram Desktop 7.1.1 — появился WEB-прокси](https://habr.com/ru/news/1073330/)
- [Telegram Desktop 7.1.2 — доработки](https://habr.com/ru/news/1074112/)
- [Технические подробности WEB-прокси](https://kod.ru/telegram-web-proxy-tproxy-server-podrobnosti)

## Лицензия

MIT — см. [LICENSE](LICENSE).
