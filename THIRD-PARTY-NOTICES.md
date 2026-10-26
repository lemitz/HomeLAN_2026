# Third-party notices

HomeLAN itself is licensed under the [MIT License](LICENSE). The release binaries also contain the third-party components listed below, each under its own licence. The full licence texts ship inside the respective packages (Go module cache, pub cache) and, for the Flutter apps, are shown by Flutter's built-in licence registry.

## Server (`homelan-server`)

Built with Go (BSD-3-Clause, The Go Authors) and cgo.

| Component | Licence | Notes |
|---|---|---|
| [mutecomm/go-sqlcipher](https://github.com/mutecomm/go-sqlcipher) v4 | MIT (code from mattn/go-sqlite3) | bundles the components below |
| ↳ [SQLCipher](https://www.zetetic.net/sqlcipher/) | BSD-3-Clause, Zetetic LLC | database encryption |
| ↳ [SQLite](https://sqlite.org/) | Public domain | |
| ↳ [LibTomCrypt](https://github.com/libtom/libtomcrypt) | Public domain / Unlicense | crypto backend of SQLCipher |
| [gorilla/websocket](https://github.com/gorilla/websocket) | BSD-2-Clause | |
| [hashicorp/mdns](https://github.com/hashicorp/mdns) | MIT | server discovery |
| [miekg/dns](https://github.com/miekg/dns) | BSD-3-Clause | used by mdns |
| [golang.org/x/crypto](https://pkg.go.dev/golang.org/x/crypto), x/net, x/sys | BSD-3-Clause, The Go Authors | bcrypt |
| [go-yaml/yaml](https://github.com/go-yaml/yaml) v3 | MIT and Apache-2.0 | |

## Clients (Android APK, Windows app)

Built with [Flutter](https://flutter.dev) and Dart (BSD-3-Clause, The Flutter / Dart Authors), including the Flutter engine and its bundled libraries (Skia, Impeller, ICU, HarfBuzz, FreeType and others under BSD, MIT, Apache-2.0, ICU and similar permissive licences).

| Package | Licence |
|---|---|
| cryptography | Apache-2.0, Gohilla |
| flutter_secure_storage | BSD-3-Clause, German Saprykin |
| sqflite, sqflite_common_ffi | BSD-2-Clause, Alexandre Roux Tekartik |
| sqlite3, sqlite3_flutter_libs (bundles SQLite, public domain) | MIT, Simon Binder |
| web_socket_channel, http, path, mime, intl | BSD-3-Clause, The Dart Authors |
| path_provider, shared_preferences, image_picker, local_auth, multicast_dns, flutter_localizations | BSD-3-Clause, The Flutter Authors |
| provider | MIT, Remi Rousselet |
| uuid | MIT, Yulian Kuncheff |
| cupertino_icons | MIT, Vladimir Kharlampidi |
| file_picker | MIT, Miguel Ruivo |
| flutter_local_notifications | BSD-3-Clause, Michael Bui |
| open_filex | BSD-3-Clause, crazecoder |
| flutter_foreground_task | MIT, Dev-hwang |
| qr_flutter | BSD-3-Clause, Luke Freeman |
| qr | BSD-3-Clause, The Dart QR project authors |
| mobile_scanner | BSD-3-Clause, Julian Steenbakker |

**Google ML Kit.** On Android, `mobile_scanner` uses the Google ML Kit barcode scanning library, which is distributed under the [ML Kit Terms of Service](https://developers.google.com/ml-kit/terms). Barcode scanning runs entirely on the device.

## Build tools (not shipped)

Go, Flutter SDK, JDK, Gradle, Android Gradle Plugin and Kotlin Gradle Plugin (Apache-2.0), MinGW-w64 GCC, Visual Studio build tools, Inno Setup (Inno Setup licence). The Windows installer can bundle the Microsoft Visual C++ Redistributable, distributed under Microsoft's licence terms.

## Artwork

The HomeLAN icon and screenshots are the owner's own artwork and are covered by the repository licence. Material icons (Apache-2.0, Google) come with Flutter.
