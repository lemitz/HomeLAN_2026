<h1 align="center">HomeLAN</h1>

<p align="center">
  Приватный мессенджер со сквозным шифрованием для двух человек в домашней сети.<br>
  Свой сервер на Orange Pi, клиенты для Android и Windows. Без интернета, облаков и телеметрии.
</p>

<p align="center">
  <a href="https://github.com/lemitz/HomeLAN_2026/releases"><img src="https://img.shields.io/badge/version-1.0.0-4c8dff" alt="Версия 1.0.0"></a>
  <img src="https://img.shields.io/badge/client-Android%20%7C%20Windows%20x64-3ddc84" alt="Android и Windows">
  <img src="https://img.shields.io/badge/server-Linux%20arm64%20%7C%20amd64%20%7C%20Windows-0078d4" alt="Сервер для Linux и Windows">
  <img src="https://img.shields.io/badge/built%20with-Go%20%2B%20Flutter-00add8" alt="Go и Flutter">
  <img src="https://img.shields.io/badge/E2E-XChaCha20--Poly1305-2ea043" alt="Сквозное шифрование">
  <img src="https://img.shields.io/badge/telemetry-none-2ea043" alt="Без телеметрии">
</p>

<p align="center">
  <a href="README.md">English</a> · <b>Русский</b>
</p>

---

<p align="center">
  <img src="docs/assets/homelan-client.png" width="70%" alt="Клиент HomeLAN">
</p>

## Возможности

**Шифрование**
- Сквозное: X25519 + HKDF-SHA256 + XChaCha20-Poly1305. Сервер хранит только шифротексты и не принимает незашифрованное
- Служебные поля защищены (отправитель, получатель, тип, id сообщения): сервер не может подделать, развернуть или подменить сообщение
- Один ключ на человека. Новое устройство получает его по **двум QR-кодам** (или текстом, если нет камеры), зашифрованным только для него
- **Отпечатки ключей:** ключ собеседника закрепляется при первом контакте; если он сменится, отправка блокируется до сверки

**Переписка**
- Текст, фото и файлы до 2 ГБ, шифруются и загружаются потоком
- Галочки доставки и прочтения, «печатает», удаление у всех, поиск
- Синхронизация без потерь: курсор изменений приносит новые сообщения, статусы и удаления; неотправленное уходит повторно без дублей
- Русский или английский по языку системы; плавные анимации на частоте экрана (120/144 Гц, где поддерживается)

**Сервер**
- База SQLCipher, ключ на USB-флешке
- Вайп при извлечении флешки, duress-пароль (по желанию), Dead Man's Switch; вайп уничтожает и ключ на флешке
- Ограничение попыток входа, скользящие сессии, мгновенный отзыв устройств, поиск сервера через mDNS

**Клиенты**
- Android: блокировка биометрией / PIN, запрет скриншотов, без облачных бэкапов
- Windows: окно скрыто от захвата экрана; без связи с сервером переписка не показывается

> Прочитайте [SECURITY.md](SECURITY.md) и [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md): пока нет Perfect Forward Secrecy, вход и метаданные идут по HTTP внутри сети, а сервер, изъятый вместе со вставленной флешкой, можно расшифровать.

## Установка

Скачайте со страницы [Releases](https://github.com/lemitz/HomeLAN_2026/releases):

- **Сервер:** `homelan-server-<версия>-linux-arm64.tar.gz` (Orange Pi, Raspberry Pi 64-bit), `-linux-amd64.tar.gz` или `-windows-amd64.zip`. Распакуйте, один раз создайте ключ на флешке `./homelan-server --init-usb`, затем запустите `./homelan-server`. Подробно: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).
- **Android:** `HomeLAN-<версия>-android.apk`.
- **Windows:** `HomeLAN-<версия>-windows-x64-setup.exe` (установщик) или `HomeLAN-<версия>-windows-x64.zip` (портативная версия, папку держите целиком).
- `SHA256SUMS.txt` — контрольные суммы: `sha256sum -c SHA256SUMS.txt --ignore-missing` или в PowerShell `Get-FileHash <файл> -Algorithm SHA256`.

Файлы не подписаны: Windows SmartScreen может предупредить (*Подробнее* → *Выполнить в любом случае*), Android попросит разрешить установку из браузера или файлового менеджера.

**Первый запуск:** клиенты сами находят сервер через mDNS; если не нашли — нажмите на адрес сервера на экране входа и введите его. Каждый регистрируется на своём первом устройстве (первый становится админом). Затем сверьте отпечатки: меню чата → *Отпечаток ключей*.

## Разработка

Нужно: Go 1.22+ с C-компилятором (cgo для SQLCipher; на Windows — MinGW-w64), Flutter 3.38+, для APK — JDK 17 и Android SDK.

```bash
cd homelan-server
go vet ./... && go test -race ./...
go run ./cmd/server --key-file ./dev.key     # только для разработки: ключ из файла вместо флешки

cd client
flutter analyze && flutter test
flutter run -d windows
```

`client/test/e2e_server_test.dart` гоняет настоящий клиентский код против запущенного сервера (`HOMELAN_E2E_URL=http://127.0.0.1:8080 flutter test test/e2e_server_test.dart`).

## Релизы

Всё делает [`build.yml`](.github/workflows/build.yml):

- **Pull request в `main`:** форматирование, `go vet`, тесты Go (с race-детектором), `flutter analyze` и тесты; сервер для Linux arm64/amd64 и Windows, APK и Windows-клиент прикрепляются к запуску как артефакты. Запуск пишет, выпустит ли мердж релиз.
- **Мердж в `main`:** та же сборка, затем **GitHub Release `v<VERSION>`** со всеми файлами и `SHA256SUMS.txt`; текст — [`RELEASE_NOTES.md`](RELEASE_NOTES.md) плюс список влитых PR. Если такой тег уже есть, ничего не публикуется.
- **Кнопка «Run workflow»:** собирает любую ветку, никогда не публикует.

Чтобы выпустить релиз, поднимите версию в [`VERSION`](VERSION), `client/pubspec.yaml`, `client/lib/version.dart` и `Version` в `homelan-server/cmd/server/main.go`, а `RELEASE_NOTES.md` начните с `# HomeLAN v<версия>`. Всё это проверяет `./scripts/check-release.ps1`, workflow тоже его запускает.

**Подпись APK.** `./scripts/make-keystore.ps1` создаёт ключ релиза вне репозитория и кладёт его в секреты `HOMELAN_KEYSTORE_BASE64`, `HOMELAN_KEYSTORE_PASSWORD`, `HOMELAN_KEY_ALIAS` и `HOMELAN_KEY_PASSWORD`. Храните резервную копию: без ключа обновить приложение можно будет только через удаление.

## Структура

```
VERSION                  версия всего проекта
homelan-server/          сервер (Go): cmd/server, internal/{server,db,ws,linking,panic,usb,ratelimit,mdns,config}
client/                  клиент (Flutter): lib/{services,providers,screens,widgets,models,l10n}
docs/                    ARCHITECTURE, THREAT_MODEL, DEPLOYMENT
scripts/                 check-release.ps1, make-keystore.ps1
homelan_setup.iss        установщик Windows (Inno Setup)
.github/workflows/       сборка и релизы
```

## Лицензия

HomeLAN распространяется по [лицензии MIT](LICENSE). Сторонние компоненты и их лицензии перечислены в [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

---

<p align="center">
  <img src="https://img.shields.io/badge/Made%20with-AI-8b5cf6" alt="Made with AI"><br>
  <sub>Проект сделан с помощью ИИ-инструментов.</sub>
</p>
