# Развёртывание HomeLAN Messenger

## 1. Сервер

### Требования
* Linux (Orange Pi Zero 3, Raspberry Pi, x86_64) или Windows.
* USB-флешка для ключа шифрования БД.
* Сборка: Go 1.22+ и C-компилятор (cgo нужен для SQLCipher; на Windows — MinGW-w64).
* Статический IP в домашней сети (или mDNS — клиенты найдут сервер сами).

### Сборка

```bash
cd homelan-server
go test ./...
go build -o homelan-server ./cmd/server
```

Для Orange Pi (arm64) собирайте на самом устройстве или кросс-компилятором с cgo.

### Конфигурация

Скопируйте `config.yaml` рядом с бинарником и проверьте параметры (все описаны в
файле): порт, лимиты пользователей и устройств, квота и срок хранения файлов,
Dead Man's Switch, duress-пароль (по умолчанию выключен).

### USB-ключ

```bash
./homelan-server --init-usb              # спросит, на какую флешку записать
./homelan-server --init-usb --drive /media/pi/KEY
```

Существующий `homelan.key` **не перезаписывается** (иначе база станет
нечитаемой); перезапись — только с `--force`. Сделайте резервную копию ключа и
храните её отдельно от сервера.

### Запуск и автозапуск (systemd)

```ini
[Unit]
Description=HomeLAN Messenger Server
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/homelan
ExecStart=/opt/homelan/homelan-server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

> `Restart=on-failure` — после вайпа процесс завершается с кодом 1; без флешки
> сервер не стартует, так что перезапуск безопасен.

Если порт 5353 занят `avahi-daemon`, встроенный mDNS не запустится — клиенты
тогда подключаются по IP (адрес вводится на экране входа).

### Обновление с v0.x

Схема БД v2 несовместима со старой. Сервер откажется стартовать со старой базой —
удалите каталог `data/` (переписка v0.x не переносится: она была зашифрована
старым протоколом).

## 2. Клиенты

```bash
cd client
flutter test
flutter build apk --release        # Android
flutter build windows --release    # Windows
```

* **Подпись Android**: создайте `android/key.properties` (см. комментарий в
  `android/app/build.gradle`). Без него релиз подписывается debug-ключом.
* **Инсталлятор Windows**: `homelan_setup.iss` (Inno Setup 6). Положите рядом
  `vc_redist.x64.exe`, чтобы он ставился на чистые системы.

### Первый запуск

1. Клиент ищет сервер через mDNS; если не нашёл — укажите адрес на экране входа
   («Сервер: ...»).
2. **Регистрация** на первом устройстве каждого пользователя. Первый
   зарегистрированный — администратор.
3. **Сверьте отпечатки ключей** с собеседником лично: меню чата →
   «Отпечаток ключей» → «Совпадает».

### Новое устройство того же пользователя

1. На новом устройстве: «Привязать к аккаунту» — появится QR и код сверки.
2. На основном: «Мои устройства» → «Добавить устройство» → сканировать QR или
   вставить его текст → сверить код → показать ответный QR.
3. На новом: отсканировать ответ или вставить текст.

Без камеры на любом из устройств используйте кнопки «Скопировать как текст».

## 3. Тесты

```bash
cd homelan-server && go test -race ./...
cd client && flutter test
```

Сквозной тест клиента против настоящего сервера (нужна пустая БД):

```bash
cd homelan-server && go build -o /tmp/hl/homelan-server ./cmd/server
cd /tmp/hl && echo <64 hex> > homelan.key && ./homelan-server --key-file ./homelan.key
cd client && HOMELAN_E2E_URL=http://127.0.0.1:8080 flutter test test/e2e_server_test.dart
```

`--key-file` — только для разработки и тестов: он отключает требование USB.
