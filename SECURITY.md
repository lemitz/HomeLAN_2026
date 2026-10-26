# Security

## What HomeLAN promises, and what it does not

HomeLAN is an end-to-end encrypted messenger for two people on a **home network**. The full threat model is in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md); in short:

**Protected**

- Message and file contents: X25519 + HKDF-SHA256 + XChaCha20-Poly1305, encrypted on the device. The server stores ciphertext only and rejects anything unencrypted.
- Forged, reflected or replayed messages from a malicious server: sender, recipient, type and message id are authenticated.
- Key substitution on the network (ARP/mDNS spoofing, fake server): the contact's key is pinned on first contact and verified with a safety number; a key change blocks sending.
- The server's database at rest: SQLCipher with a key on a USB stick; wipe on USB removal, optional duress password and Dead Man's Switch.
- Password guessing: bcrypt, IP lockout after repeated failures.

**Not protected (known and documented)**

- **No forward secrecy.** Identity keys are static: a leaked key decrypts all past messages an attacker has captured.
- **Plain HTTP inside the LAN.** Login, password, session token and metadata are visible to anyone on the network. Use a closed WPA2/WPA3 network.
- **Metadata** (who, when, sizes, delivery status) is visible to the server.
- **A server seized with the USB stick inserted** and simply powered off can be decrypted.
- A lost or stolen device keeps its identity key; revoking it cuts access to the server but does not change the key.

Do not expose the server port (8080 by default) to the internet.

## Reporting a problem

If you find a way to read message contents without the keys, impersonate a user or device, bypass device revocation, read or write files outside the server's data directory, crash the server from the network, or make HomeLAN do anything its description above does not allow, please report it **privately** through [GitHub security advisories](https://github.com/lemitz/HomeLAN_2026/security/advisories/new) rather than a public issue. Weaknesses listed under "Not protected" are known.
