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

```bash
git clone https://github.com/SkunkBG/TGweb.git
cd TGweb
sudo bash install.sh
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

## Диагностика

| Симптом | Куда смотреть |
|---|---|
| Сертификат не выпускается | A-запись ведёт напрямую на сервер? Cloudflare в DNS only? 80 и 443 доходят до Caddy? `journalctl -u caddy -n 60` |
| `/readyz` отдаёт 503 | `systemctl status mtproxy`, `ss -lntp \| grep 2398` |
| В WebView открывается публичный сайт | hostname и secret в клиенте не совпадают с профилем на сервере |
| Порт 80 или 443 занят | остановите свой веб-сервер: `systemctl disable --now nginx` |
| Permission denied на профилях | `chmod 400 /etc/tproxy-server/profiles.json` |

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
