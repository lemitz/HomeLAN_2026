<p align="center">
  <img src="docs/assets/icon.png" width="128" alt="HomeLAN logo">
</p>

<h1 align="center">HomeLAN</h1>

<p align="center">
  A private end-to-end encrypted messenger for two people on a home network.<br>
  Your own server on an Orange Pi, apps for Android and Windows. No internet, no cloud, no accounts elsewhere, no telemetry, no nonsense.
</p>

<p align="center">
  <a href="https://github.com/lemitz/HomeLAN_2026/releases"><img src="https://img.shields.io/badge/version-1.0.0-8b8cff" alt="Version 1.0.0"></a>
  <img src="https://img.shields.io/badge/client-Android%20%7C%20Windows%2010%20%7C%2011%20x64-3ddc84" alt="Android, Windows 10 / 11 x64">
  <img src="https://img.shields.io/badge/server-Linux%20arm64%20%7C%20amd64%20%7C%20Windows-0078d4" alt="Server: Linux arm64 / amd64, Windows">
  <img src="https://img.shields.io/badge/built%20with-Go%20%7C%20Flutter-00add8" alt="Go / Flutter">
  <img src="https://img.shields.io/badge/E2E-X25519%20%7C%20XChaCha20--Poly1305-e8590c" alt="E2E: X25519 / XChaCha20-Poly1305">
  <img src="https://img.shields.io/badge/telemetry-none-2ea043" alt="No telemetry">
  <a href="https://github.com/lemitz/HomeLAN_2026/actions/workflows/build.yml"><img src="https://github.com/lemitz/HomeLAN_2026/actions/workflows/build.yml/badge.svg" alt="Build status"></a>
</p>

<p align="center">
  <b>English</b> · <a href="README.ru.md">Русский</a>
</p>

---

HomeLAN is a messenger for exactly two people — say, you and your partner — and the handful of phones and PCs you own. The server is a small Go program that runs on a single-board computer in your flat and keeps the conversation; the apps talk to it over your Wi-Fi and nothing ever leaves the local network.

The server is trusted with as little as possible. Messages and files are encrypted on the device with keys the server never sees, so the server stores ciphertext and nothing else, and it refuses anything that is not encrypted. Its own database is encrypted too, with a key that lives on a USB stick: pull the stick out and the server wipes itself. If the server is ever replaced or tampered with, the apps notice — the other person's key is pinned on first contact and can be checked with a safety number.

## Features

**Encryption**
- End-to-end: X25519 key agreement, HKDF-SHA256, XChaCha20-Poly1305 with a random 24-byte nonce per message
- Sender, recipient, message type and message id are authenticated inside every message, so the server cannot forge a message, bounce your own message back as the other person's, swap a text for a file or replay an old one
- One identity key per person, kept in the system keystore (Android Keystore, Windows DPAPI). It never travels in the clear: a new device receives it encrypted for that device only
- **Safety numbers:** 60 digits that are the same on both phones. The contact's key is pinned the first time it is seen; if the server ever presents a different one, sending stops until you compare the numbers and accept the new key
- The app checks its own key against the account key on the server at every sign-in and refuses to continue if they differ

**Messaging**
- Text, photos and files up to 2 GB. Files are encrypted chunk by chunk with their own key and uploaded as a stream, so a large file never sits in memory
- Sent / delivered / read ticks, typing indicator, delete for everyone, search with `*` and `?` wildcards, date separators, grouped bubbles
- Nothing gets lost: every message waits in a local outbox until the server confirms it, and is resent after reconnecting without creating duplicates. A change cursor brings back new messages, read receipts and deletions after any time offline
- The server is the source of truth: the app keeps only ciphertext as a cache, and a fresh install or a new device downloads the whole history again
- Images are decrypted on demand into a temporary folder that is cleared at every start; opening an executable file asks first

**Devices**
- Each person can use up to three devices (configurable). Password sign-in works only on a device that is already linked
- **Linking with two QR codes:** the new device shows a QR code with a one-time key, the old one scans it, both show the same 6-digit check code, and the old device answers with a second QR code carrying the encrypted identity key. No camera on the PC? Both steps work with copy and paste
- A device list with online status and last seen; revoking a device cuts it off instantly, over HTTP and the live connection alike

**Server**
- SQLCipher (AES-256) database; the key is a file on a USB stick and is checked every second
- Emergency wipe when the stick is removed, on an optional duress password, after the admin has been away for a set number of days (Dead Man's Switch), or on request from the admin with the password. A wipe also destroys the key on the stick, so leftover flash blocks stay unreadable
- bcrypt passwords, lockout after repeated failures, sliding sessions stored as hashes, storage quota and retention for files
- Advertises itself over mDNS, so the apps find it without typing an address

**Look and feel**
- Dark interface, smooth animations: messages slide in, screens fade, ticks change in place
- Asks for the highest refresh rate the display offers (120/144 Hz on Android and Windows); the chat list rebuilds only when messages actually change
- English or Russian, following the system language, switchable in Settings

**Privacy on the device**
- Android: biometric or PIN lock at start and on every return from the background (the lock covers the app without losing what was open), screenshots and the recent-apps preview blocked, no cloud backups
- Windows: the window is excluded from screen capture; the conversation stays hidden while the server is unreachable

> Read [SECURITY.md](SECURITY.md) and [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) before trusting HomeLAN with anything serious. In short: there is no forward secrecy yet, sign-in and metadata travel over plain HTTP inside the LAN, and a server seized together with the inserted USB stick can be decrypted.

## How it works

```
 Android / Windows app                       homelan-server (Orange Pi)
 ┌───────────────────────────┐   Wi-Fi    ┌────────────────────────────────┐
 │ identity key (keystore)   │  HTTP +    │ users, devices, sessions       │
 │ encrypt / decrypt         │ WebSocket  │ messages: ciphertext only      │
 │ outbox + ciphertext cache ├───────────►│ files: encrypted blobs         │
 │ pinned contact key        │            │ SQLCipher DB ── key on USB     │
 └───────────────────────────┘            └────────────────────────────────┘
```

Message key: `HKDF-SHA256(X25519(mine, theirs))`, message: `0x02 | nonce | XChaCha20-Poly1305(text, aad = sender|recipient|type|id)`. The protocol, the sync model and the linking flow are described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Controls

| Action | How |
|---|---|
| Send | `Enter` on the PC (`Shift+Enter` for a new line), the arrow button on the phone |
| Attach a photo or file | `+` next to the input field |
| Copy, resend, delete a message | Long-press on the phone, right-click on the PC |
| Open a photo full screen | Tap it; tap again to close, pinch to zoom |
| Search the conversation | The magnifier in the top bar |
| Safety number, devices, contact name and colour, settings | `⋮` in the top bar |
| Change the server address | Tap the address under the sign-in form |

## Installation

Download from the [Releases](https://github.com/lemitz/HomeLAN_2026/releases) page:

| File | What it is |
|---|---|
| `homelan-server-<version>-linux-arm64.tar.gz` | Server for Orange Pi, Raspberry Pi and other 64-bit ARM boards |
| `homelan-server-<version>-linux-amd64.tar.gz` | Server for x86-64 Linux |
| `homelan-server-<version>-windows-amd64.zip` | Server for Windows |
| `HomeLAN-<version>-android.apk` | Android app |
| `HomeLAN-<version>-windows-x64-setup.exe` | Windows app, installer (adds the Visual C++ runtime if needed) |
| `HomeLAN-<version>-windows-x64.zip` | Windows app, portable — keep the folder together |
| `SHA256SUMS.txt` | Checksums: `sha256sum -c SHA256SUMS.txt --ignore-missing`, or `Get-FileHash <file> -Algorithm SHA256` in PowerShell |

The binaries are not code-signed, so Windows SmartScreen may warn (*More info* → *Run anyway*) and Android asks to allow installing from your browser or file manager. Every release APK is signed with the project's own key, so a newer release installs over the old one.

### Server

```bash
tar -xzf homelan-server-1.0.0-linux-arm64.tar.gz && cd homelan-server-1.0.0-linux-arm64
./homelan-server --init-usb      # once: writes homelan.key to a USB stick (never overwrites an existing key)
./homelan-server                 # finds the stick, opens the database, listens on :8080
```

Settings live in `config.yaml` next to the binary: port, user and device limits, file size, quota and retention, Dead Man's Switch, duress password. Back up `homelan.key` — without it the database cannot be opened. A systemd unit and the rest of the setup are in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

### First start

1. Open the app. It finds the server over mDNS; if it does not, tap the address under the sign-in form and type the server's IP.
2. Each person creates an account on their first device. The first account becomes the admin.
3. Compare safety numbers once, in person: `⋮` → *Safety number* → *Matches*. A green check appears next to the name.
4. More devices: on the new one tap *Link to account*, on an existing one open *Devices* → *Add device*.

## Development

Requirements:

- Go 1.22+ and a C compiler for cgo (SQLCipher); MinGW-w64 on Windows
- Flutter 3.38+; for the APK JDK 17 and the Android SDK; for the Windows app Visual Studio with *Desktop development with C++*

```bash
cd homelan-server
go vet ./... && go test -race ./...
go run ./cmd/server --key-file ./dev.key      # development only: a key file instead of a USB stick

cd client
flutter analyze && flutter test
flutter run -d windows                        # or a connected phone
```

The server tests run the whole protocol through real HTTP and WebSocket: registration, rate limiting, duress, linking, revocation, messages, receipts, sync with deletions, files with Range requests, panic and the Dead Man's Switch. The client tests cover the message cipher (including tampering, reflection and type swaps), key pinning, safety numbers, the linking crypto and the file cipher. `client/test/e2e_server_test.dart` drives the real client code against a running server:

```bash
HOMELAN_E2E_URL=http://127.0.0.1:8080 flutter test test/e2e_server_test.dart
```

## Releasing

[`build.yml`](.github/workflows/build.yml) does everything:

- **Pull request to `main`:** `gofmt`, `go vet`, Go tests with the race detector, `flutter analyze` and tests; the server for linux-amd64, linux-arm64 and windows-amd64, the signed APK, the Windows zip and installer are attached to the run as artifacts. The run says whether merging will publish a release.
- **Merge to `main`:** the same build, then a **GitHub Release `v<VERSION>`** with every file and `SHA256SUMS.txt`, using [`RELEASE_NOTES.md`](RELEASE_NOTES.md) plus the list of merged pull requests. If the tag already exists, nothing is published, so ordinary pull requests only build.
- **"Run workflow" button:** builds any branch, never publishes.

### Versioning

Versions are `MAJOR.MINOR.PATCH`:

- **PATCH** (1.0.0 → 1.0.1): bug fixes only.
- **MINOR** (1.0.0 → 1.1.0): new features that keep the server database and the protocol compatible.
- **MAJOR** (1.x → 2.0.0): a change that breaks the database or the protocol and needs a fresh start.

To ship a release, bump [`VERSION`](VERSION), `version:` in `client/pubspec.yaml`, `appVersion` in `client/lib/version.dart` and `Version` in `homelan-server/cmd/server/main.go`, and start `RELEASE_NOTES.md` with `# HomeLAN v<version>`. `./scripts/check-release.ps1` checks that they all agree; the workflow runs it too. Merge, and the release appears.

**Signing the APK.** `./scripts/make-keystore.ps1` creates the release key outside the repository and stores it in the `HOMELAN_KEYSTORE_BASE64`, `HOMELAN_KEYSTORE_PASSWORD`, `HOMELAN_KEY_ALIAS` and `HOMELAN_KEY_PASSWORD` secrets. Keep a backup of the key: with a lost key, everyone has to uninstall the app to update it.

## Known limitations

- Exactly two people per server, by design.
- No forward secrecy and no automatic key rotation: identity keys are static (see [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)).
- The transport is plain HTTP inside the LAN; message contents are protected end to end, the password at sign-in and metadata are not.
- No backup of the identity key: if a person loses every device, their old messages cannot be read again.
- Windows has no app lock of its own; the conversation is hidden only while the server is unreachable.
- Auto-deleting messages is supported by the server but has no button in the apps yet.
- No iOS or macOS builds.

## Project structure

```
VERSION                          the version of everything
homelan-server/
  cmd/server/main.go             flags (--init-usb, --key-file, --version), startup, shutdown
  config.yaml                    example configuration
  internal/
    server/                      HTTP API, auth middleware, handlers, files, maintenance, USB watch
    db/                          SQLCipher schema v2: users, devices, sessions, messages, files
    ws/                          WebSocket hub and protocol v2: send, sync, history, ack, read, delete
    linking/                     one-time device link codes bound to the new device
    ratelimit/                   lockout after repeated failures
    panic/                       emergency wipe (database, files, USB key)
    usb/                         finding and creating homelan.key
    mdns/                        _homelan._tcp advertisement
    config/                      configuration and defaults
client/lib/
  main.dart                      providers, theme, localization, lock and server guard overlays
  l10n/strings.dart              English and Russian strings
  theme.dart                     colours, theme, page transitions
  services/                      crypto, file cipher, API, WebSocket, local cache, linking formats, ...
  providers/                     auth (session, keys, linking) and chat (sync, outbox, files)
  screens/                       sign-in, chat, settings, devices, linking, safety number, lock
  widgets/                       message bubble, UI kit and animations, QR scanner, server address
client/test/                     crypto, linking and file cipher tests; end-to-end test
docs/                            ARCHITECTURE, THREAT_MODEL, DEPLOYMENT (in Russian)
scripts/                         check-release.ps1, make-keystore.ps1
homelan_setup.iss                Windows installer (Inno Setup)
.github/workflows/build.yml      tests and builds on every pull request; release when VERSION changes
```

## Tech stack

[Go](https://go.dev) · [SQLCipher](https://www.zetetic.net/sqlcipher/) ([go-sqlcipher](https://github.com/mutecomm/go-sqlcipher)) · [gorilla/websocket](https://github.com/gorilla/websocket) · [hashicorp/mdns](https://github.com/hashicorp/mdns) · [Flutter](https://flutter.dev) · [cryptography](https://pub.dev/packages/cryptography) · [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) · [sqflite](https://pub.dev/packages/sqflite) · [mobile_scanner](https://pub.dev/packages/mobile_scanner) · [Inno Setup](https://jrsoftware.org/isinfo.php) · [GitHub Actions](https://github.com/features/actions)

## License

HomeLAN is released under the [MIT License](LICENSE). Third-party components keep their own licenses; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

---

<p align="center">
  <img src="https://img.shields.io/badge/Made%20with-AI-8b5cf6" alt="Made with AI"><br>
  <sub>This project was built with the help of AI tools.</sub>
</p>
