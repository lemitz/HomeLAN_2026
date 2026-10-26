# HomeLAN v1.0.0

First public release of HomeLAN, a private end-to-end encrypted messenger for two people on a home network: your own server on an Orange Pi (or any Linux/Windows box), Android and Windows clients, no internet, no cloud, no telemetry.

## Changes

- **Protocol v2, rebuilt to the original architecture.** One identity key per person (X25519), message keys via HKDF-SHA256, XChaCha20-Poly1305 with authenticated metadata (sender, recipient, type, message id). The server rejects anything that is not encrypted.
- **Safety numbers and key pinning.** The contact's key is pinned on first contact; if the server ever sends a different key, sending is blocked until you compare the safety number in person.
- **Device linking with two QR codes**, or copy-paste text when there is no camera. The identity key travels encrypted to the new device; the server never sees it.
- **Lossless sync.** A change cursor delivers new messages, read receipts and deletions; an outbox resends anything that did not get through, without duplicates.
- **Files up to 2 GB**, encrypted and uploaded as a stream, never loaded into memory.
- **Server security:** SQLCipher database, key on a USB stick; wipe on USB removal, optional duress password, Dead Man's Switch; a wipe also destroys the key on the stick. Rate limiting, sliding sessions, instant device revocation.
- **New interface** in Russian and English (follows the system language, can be changed in Settings), smooth animations, high refresh rate (120/144 Hz on Android and Windows where the display supports it).
- **Client protection:** biometric/PIN lock, screenshots blocked, no cloud backups.
- Releases are built by GitHub Actions when a pull request that bumps `VERSION` is merged.

## Downloads

- `HomeLAN-1.0.0-android.apk` - the Android app.
- `HomeLAN-1.0.0-windows-x64-setup.exe` - the Windows app, installer.
- `HomeLAN-1.0.0-windows-x64.zip` - the Windows app, portable (keep the folder together).
- `homelan-server-1.0.0-linux-arm64.tar.gz` - the server for Orange Pi / Raspberry Pi (64-bit).
- `homelan-server-1.0.0-linux-amd64.tar.gz` - the server for x86-64 Linux.
- `homelan-server-1.0.0-windows-amd64.zip` - the server for Windows.
- `SHA256SUMS.txt` - checksums for all files.

The binaries are not code-signed, so Windows SmartScreen may show a warning ("More info" → "Run anyway"), and Android asks you to allow installing from your browser or file manager.

To verify a download, run `sha256sum -c SHA256SUMS.txt --ignore-missing` on Linux, or `Get-FileHash .\HomeLAN-1.0.0-android.apk -Algorithm SHA256` in PowerShell and compare with `SHA256SUMS.txt`.

## Good to know

- **Not compatible with v0.x.** Delete the server's `data/` directory before the first start; old messages used the old protocol and cannot be migrated.
- Passwords are at least 8 characters. New devices are added only by linking from an existing one.
- If you installed a locally built APK before, uninstall it first: the release APK is signed with a different key.
- Read `docs/THREAT_MODEL.md`: no forward secrecy yet; login and metadata travel over plain HTTP inside the LAN; a server seized together with the inserted USB stick can be decrypted.
- Setup guide: `docs/DEPLOYMENT.md`.
