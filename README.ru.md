# TrustTunnel одной командой

[English version](README.md)

Этот репозиторий разворачивает официальный
[TrustTunnel](https://github.com/TrustTunnel/TrustTunnel) на чистом VPS с
Ubuntu или Debian. Собственного VPN-движка здесь нет: установщик скачивает
официальный релиз и проверяет подписи обоих бинарников официальным GPG-ключом
AdGuard.

## Установка

1. Направьте DNS-запись `A`, например `vpn.example.com`, на IP сервера.
2. Откройте у провайдера `22/tcp`, `80/tcp`, `443/tcp` и `443/udp`.
3. Выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/radislabus-star/trusttunnel-one-click/main/install.sh | sudo bash
```

Скрипт спросит домен и почту для Let's Encrypt. Пароль VPN он сгенерирует сам,
затем покажет готовую ссылку `tt://` и QR-код.

Перед запуском скрипт можно прочитать:

```bash
curl -fsSL https://raw.githubusercontent.com/radislabus-star/trusttunnel-one-click/main/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

Автоматический запуск без вопросов:

```bash
curl -fsSL https://raw.githubusercontent.com/radislabus-star/trusttunnel-one-click/main/install.sh \
  | sudo env TT_DOMAIN=vpn.example.com TT_EMAIL=admin@example.com bash
```

## Что настраивается

- официальный TrustTunnel для `x86_64` или `aarch64`;
- HTTP/1.1, HTTP/2 и HTTP/3/QUIC на одном порту;
- сертификат Let's Encrypt и автоматическое продление;
- systemd с автозапуском и перезапуском после сбоя;
- BBR/FQ, если ядро их поддерживает;
- TCP и UDP правила в уже активном `ufw` или `firewalld`;
- команда `ttctl` для пользователей, QR-кодов, логов и диагностики.

Установщик не включает firewall сам, не меняет SSH и не открывает панель
управления наружу.

## Управление

```bash
sudo ttctl doctor
sudo ttctl status
sudo ttctl users
sudo ttctl add-user alice
sudo ttctl qr alice
sudo ttctl remove-user alice
sudo ttctl logs
sudo ttctl update
```

Повторный запуск установщика означает обновление. Перед заменой бинарников он
делает закрытую резервную копию в `/var/backups/trusttunnel`, сохраняет
пользователей и настройки, а при неудачном старте возвращает прежний бинарник.

## Требования

- Ubuntu 22.04/24.04 или Debian 12;
- root или `sudo`;
- публичный IPv4;
- домен должен указывать прямо на VPS, без CDN-прокси;
- порт `80/tcp` должен оставаться доступным для продления сертификата;
- порт `443` должен быть свободен по TCP и UDP.

Если у хостера есть отдельный облачный firewall, порты нужно открыть и там.

## Удаление

```bash
curl -fsSL https://raw.githubusercontent.com/radislabus-star/trusttunnel-one-click/main/uninstall.sh | sudo bash
```

Конфигурация перед удалением архивируется. Сертификат Let's Encrypt и правила
firewall намеренно сохраняются.

Проект независимый и не связан с TrustTunnel или AdGuard. Лицензия Apache-2.0.
