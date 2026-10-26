<h1 align="center">HomeLAN</h1>

<p align="center">
  A private end-to-end encrypted messenger for two people on a home network.<br>
  Your own server on an Orange Pi, Android and Windows clients. No internet, no cloud, no telemetry.
</p>

<p align="center">
  <a href="https://github.com/lemitz/HomeLAN_2026/releases"><img src="https://img.shields.io/badge/version-1.0.0-4c8dff" alt="Version 1.0.0"></a>
  <img src="https://img.shields.io/badge/client-Android%20%7C%20Windows%20x64-3ddc84" alt="Android and Windows">
  <img src="https://img.shields.io/badge/server-Linux%20arm64%20%7C%20amd64%20%7C%20Windows-0078d4" alt="Linux and Windows server">
  <img src="https://img.shields.io/badge/built%20with-Go%20%2B%20Flutter-00add8" alt="Go and Flutter">
  <img src="https://img.shields.io/badge/E2E-XChaCha20--Poly1305-2ea043" alt="End-to-end encrypted">
  <img src="https://img.shields.io/badge/telemetry-none-2ea043" alt="No telemetry">
</p>

<p align="center">
  <b>English</b> · <a href="README.ru.md">Русский</a>
</p>

---

<p align="center">
  <img src="docs/assets/homelan-client.png" width="70%" alt="HomeLAN client">
</p>

## Features

**Encryption**
- End-to-end: X25519 + HKDF-SHA256 + XChaCha20-Poly1305. The server stores ciphertext only and rejects anything unencrypted
- Metadata inside the ciphertext is authenticated (sender, recipient, type, message id): the server cannot forge, reflect or swap messages
- One identity key per person. New devices get it through **two QR codes** (or copy-paste text without a camera), encrypted for that device only
- **Safety numbers:** the contact's key is pinned on first contact; if it ever changes, sending is blocked until you compare the numbers

**Messaging**
- Text, photos and files up to 2 GB, encrypted and uploaded as a stream
- Delivered / read ticks, typing indicator, delete for everyone, search
- Lossless sync: a change cursor brings new messages, statuses and deletions; an outbox resends what did not get through, without duplicates
- Russian or English, following the system language; smooth animations at the display's refresh rate (120/144 Hz where supported)

**Server**
- SQLCipher database, the key lives on a USB stick
- Wipe when the stick is removed, optional duress password, Dead Man's Switch; a wipe also destroys the key on the stick
- Rate limiting, sliding sessions, instant device revocation, mDNS discovery

**Clients**
- Biometric / PIN lock on Android, screenshots blocked, no cloud backups
- Windows: the window is hidden from screen capture; content stays hidden while the server is unreachable

> Read [SECURITY.md](SECURITY.md) and [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md): there is no forward secrecy yet, login and metadata travel over plain HTTP inside the LAN, and a server seized together with the inserted USB stick can be decrypted.

## Installation

Download from the [Releases](https://github.com/lemitz/HomeLAN_2026/releases) page:

- **Server:** `homelan-server-<version>-linux-arm64.tar.gz` (Orange Pi, Raspberry Pi 64-bit), `-linux-amd64.tar.gz` or `-windows-amd64.zip`. Unpack, create the USB key once with `./homelan-server --init-usb`, then run `./homelan-server`. Full guide: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).
- **Android:** `HomeLAN-<version>-android.apk`.
- **Windows:** `HomeLAN-<version>-windows-x64-setup.exe` (installer) or `HomeLAN-<version>-windows-x64.zip` (portable, keep the folder together).
- `SHA256SUMS.txt` - checksums: `sha256sum -c SHA256SUMS.txt --ignore-missing`, or in PowerShell `Get-FileHash <file> -Algorithm SHA256`.

The binaries are not code-signed: Windows SmartScreen may warn (*More info* → *Run anyway*), Android asks to allow installing from your browser or file manager.

**First start:** the clients find the server via mDNS; if not, tap the server address on the sign-in screen and type it. Each person signs up on their first device (the first one becomes admin). Then compare safety numbers: chat menu → *Safety number*.

## Development

Requirements: Go 1.22+ with a C compiler (cgo, for SQLCipher; MinGW-w64 on Windows), Flutter 3.38+, JDK 17 and the Android SDK for the APK.

```bash
cd homelan-server
go vet ./... && go test -race ./...
go run ./cmd/server --key-file ./dev.key     # development only: key file instead of a USB stick

cd client
flutter analyze && flutter test
flutter run -d windows
```

`client/test/e2e_server_test.dart` runs the real client code against a running server (`HOMELAN_E2E_URL=http://127.0.0.1:8080 flutter test test/e2e_server_test.dart`).

## Releasing

[`build.yml`](.github/workflows/build.yml) does everything:

- **Pull request to `main`:** formatting, `go vet`, Go tests (with the race detector), `flutter analyze` and tests; the server for Linux arm64/amd64 and Windows, the APK and the Windows app are attached to the run as artifacts. The run says whether merging will publish a release.
- **Merge to `main`:** the same build, then a **GitHub Release `v<VERSION>`** with all binaries and `SHA256SUMS.txt`, using [`RELEASE_NOTES.md`](RELEASE_NOTES.md) plus the list of merged pull requests. If the tag already exists, nothing is published.
- **"Run workflow" button:** builds any branch, never publishes.

To ship a release, bump [`VERSION`](VERSION), `client/pubspec.yaml`, `client/lib/version.dart` and `Version` in `homelan-server/cmd/server/main.go`, and start `RELEASE_NOTES.md` with `# HomeLAN v<version>`. `./scripts/check-release.ps1` checks all of it, the workflow runs it too.

**Signing the APK.** `./scripts/make-keystore.ps1` creates the release key outside the repository and stores it in the `HOMELAN_KEYSTORE_BASE64`, `HOMELAN_KEYSTORE_PASSWORD`, `HOMELAN_KEY_ALIAS` and `HOMELAN_KEY_PASSWORD` secrets. Keep a backup: with a lost key, users have to uninstall the app to update.

## Project structure

```
VERSION                  the version of everything
homelan-server/          server (Go): cmd/server, internal/{server,db,ws,linking,panic,usb,ratelimit,mdns,config}
client/                  client (Flutter): lib/{services,providers,screens,widgets,models,l10n}
docs/                    ARCHITECTURE, THREAT_MODEL, DEPLOYMENT (in Russian)
scripts/                 check-release.ps1, make-keystore.ps1
homelan_setup.iss        Windows installer (Inno Setup)
.github/workflows/       build and release
```

## Tech stack

[Go](https://go.dev) · [SQLCipher](https://www.zetetic.net/sqlcipher/) · [gorilla/websocket](https://github.com/gorilla/websocket) · [Flutter](https://flutter.dev) · [cryptography](https://pub.dev/packages/cryptography) · [GitHub Actions](https://github.com/features/actions)

## License

HomeLAN is released under the [MIT License](LICENSE). Third-party components and their licences are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

---

<p align="center">
  <img src="https://img.shields.io/badge/Made%20with-AI-8b5cf6" alt="Made with AI"><br>
  <sub>This project was built with the help of AI tools.</sub>
</p>
