// lib/services/crypto_service.dart
//
// Криптографический протокол HomeLAN v2.
//
// * У каждого ПОЛЬЗОВАТЕЛЯ один identity-ключ X25519. Он создаётся при
//   регистрации, хранится в защищённом хранилище ОС и переносится на новые
//   устройства только через 2-QR linking (зашифрованно, см. LinkCrypto).
// * Ключ сообщений: HKDF-SHA256(X25519(мой, его), salt, info=пара id).
// * Шифр: XChaCha20-Poly1305, 24-байтовый случайный nonce.
// * AAD = отправитель | получатель | тип | client_id — защищает от
//   отражения сообщения обратно, подмены типа и повторов сервером.
// * Формат: [0x02][nonce 24][ciphertext][mac 16].
// * Ключ собеседника закрепляется при первом получении (TOFU); смена ключа
//   блокирует отправку до явного подтверждения пользователем.
import 'dart:convert';
import 'dart:typed_data';
import '../l10n/strings.dart';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const int kCryptoVersion = 0x02;

class CryptoException implements Exception {
  final String message;
  CryptoException(this.message);
  @override
  String toString() => message;
}

/// Состояние ключа собеседника.
enum PeerKeyStatus {
  /// Ключ ещё не получен.
  unknown,

  /// Ключ закреплён (TOFU), но пользователь не сверял отпечаток.
  trusted,

  /// Отпечаток сверен вручную.
  verified,

  /// Сервер прислал ДРУГОЙ ключ. Отправка заблокирована.
  mismatch,
}

class CryptoService {
  static const _idPriv = 'identity_private_v2';
  static const _idPub = 'identity_public_v2';
  static const _token = 'session_token_v2';
  static const _peerPrefix = 'peer_key_v2_';
  static const _verifiedPrefix = 'peer_verified_v2_';

  static final _x25519 = X25519();
  static final _aead = Xchacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  final FlutterSecureStorage _storage;

  CryptoService({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  SimpleKeyPair? _identity;
  Uint8List? _identityPub;

  final Map<int, Uint8List> _peerKeys = {}; // закреплённые ключи
  final Map<int, Uint8List> _pendingPeerKeys = {}; // новые ключи при mismatch
  final Map<int, bool> _verified = {};
  final Map<String, SecretKey> _sharedKeys = {};

  // ============ IDENTITY ============

  Future<bool> hasIdentity() async {
    if (_identity != null) return true;
    return await _storage.read(key: _idPriv) != null;
  }

  /// Загружает identity-ключ из хранилища. Возвращает false, если его нет.
  Future<bool> loadIdentity() async {
    if (_identity != null) return true;
    final priv = await _storage.read(key: _idPriv);
    if (priv == null) return false;
    await _setIdentity(base64Decode(priv));
    return true;
  }

  /// Создаёт новый identity-ключ (при регистрации нового аккаунта).
  Future<Uint8List> generateIdentity() async {
    final seed = Uint8List.fromList(SecretKeyData.random(length: 32).bytes);
    await _setIdentity(seed);
    await _persistIdentity(seed);
    return _identityPub!;
  }

  /// Импортирует identity-ключ (при привязке устройства). Если передан
  /// [expectedPublic], ключ проверяется на соответствие серверному.
  Future<void> importIdentity(Uint8List privateKey, {Uint8List? expectedPublic}) async {
    if (privateKey.length != 32) throw CryptoException(S.current.badKeyLength);
    final pub = await publicFromPrivate(privateKey);
    if (expectedPublic != null && !_equal(pub, expectedPublic)) {
      throw CryptoException(S.current.linkKeyMismatch);
    }
    await _setIdentity(privateKey);
    await _persistIdentity(privateKey);
  }

  Future<Uint8List> identityPublicKey() async {
    if (_identityPub == null && !await loadIdentity()) {
      throw CryptoException(S.current.noLocalKey);
    }
    return _identityPub!;
  }

  /// Приватный ключ — только для передачи на новое устройство через LinkCrypto.
  Future<Uint8List> exportIdentityPrivate() async {
    if (!await loadIdentity()) throw CryptoException(S.current.noLocalKey);
    return Uint8List.fromList(await _identity!.extractPrivateKeyBytes());
  }

  Future<void> deleteIdentity() async {
    await _storage.delete(key: _idPriv);
    await _storage.delete(key: _idPub);
    _identity = null;
    _identityPub = null;
    _sharedKeys.clear();
  }

  static Future<Uint8List> publicFromPrivate(Uint8List priv) async {
    final kp = await _x25519.newKeyPairFromSeed(priv);
    return Uint8List.fromList((await kp.extractPublicKey()).bytes);
  }

  Future<void> _setIdentity(Uint8List priv) async {
    _identity = await _x25519.newKeyPairFromSeed(priv);
    _identityPub = Uint8List.fromList((await _identity!.extractPublicKey()).bytes);
    _sharedKeys.clear();
  }

  Future<void> _persistIdentity(Uint8List priv) async {
    await _storage.write(key: _idPriv, value: base64Encode(priv));
    await _storage.write(key: _idPub, value: base64Encode(_identityPub!));
  }

  // ============ SESSION TOKEN ============

  Future<void> saveToken(String token) => _storage.write(key: _token, value: token);
  Future<String?> readToken() => _storage.read(key: _token);
  Future<void> clearToken() => _storage.delete(key: _token);

  // ============ PEER KEYS (TOFU) ============

  /// Регистрирует ключ собеседника, пришедший с сервера.
  Future<PeerKeyStatus> registerPeerKey(int userId, Uint8List key) async {
    if (key.length != 32) return PeerKeyStatus.unknown;
    final pinned = await _loadPinned(userId);
    if (pinned == null) {
      await _storage.write(key: '$_peerPrefix$userId', value: base64Encode(key));
      _peerKeys[userId] = key;
      _pendingPeerKeys.remove(userId);
      return PeerKeyStatus.trusted;
    }
    if (_equal(pinned, key)) {
      _pendingPeerKeys.remove(userId);
      return peerStatus(userId);
    }
    _pendingPeerKeys[userId] = key;
    return PeerKeyStatus.mismatch;
  }

  /// Загружает закреплённые ключи (без обращения к серверу).
  Future<void> loadPinnedPeer(int userId) async {
    await _loadPinned(userId);
  }

  Future<Uint8List?> _loadPinned(int userId) async {
    if (_peerKeys.containsKey(userId)) return _peerKeys[userId];
    final v = await _storage.read(key: '$_peerPrefix$userId');
    if (v == null) return null;
    _peerKeys[userId] = base64Decode(v);
    _verified[userId] = await _storage.read(key: '$_verifiedPrefix$userId') == '1';
    return _peerKeys[userId];
  }

  PeerKeyStatus peerStatus(int userId) {
    if (_pendingPeerKeys.containsKey(userId)) return PeerKeyStatus.mismatch;
    if (!_peerKeys.containsKey(userId)) return PeerKeyStatus.unknown;
    return _verified[userId] == true ? PeerKeyStatus.verified : PeerKeyStatus.trusted;
  }

  Uint8List? peerKey(int userId) => _peerKeys[userId];

  /// Новый (непринятый) ключ собеседника при mismatch.
  Uint8List? pendingPeerKey(int userId) => _pendingPeerKeys[userId];

  /// Пользователь сверил отпечаток нового ключа и принял его.
  Future<void> acceptPendingPeerKey(int userId) async {
    final key = _pendingPeerKeys.remove(userId);
    if (key == null) return;
    await _storage.write(key: '$_peerPrefix$userId', value: base64Encode(key));
    await setVerified(userId, false);
    _peerKeys[userId] = key;
    _sharedKeys.clear();
  }

  Future<void> setVerified(int userId, bool verified) async {
    _verified[userId] = verified;
    if (verified) {
      await _storage.write(key: '$_verifiedPrefix$userId', value: '1');
    } else {
      await _storage.delete(key: '$_verifiedPrefix$userId');
    }
  }

  Future<void> forgetPeer(int userId) async {
    await _storage.delete(key: '$_peerPrefix$userId');
    await _storage.delete(key: '$_verifiedPrefix$userId');
    _peerKeys.remove(userId);
    _pendingPeerKeys.remove(userId);
    _verified.remove(userId);
    _sharedKeys.clear();
  }

  /// Safety number: 60 цифр (12 групп по 5), одинаковые у обоих собеседников.
  static Future<String> safetyNumber(Uint8List keyA, Uint8List keyB) async {
    final sorted = [keyA, keyB]..sort((a, b) => _compare(a, b));
    final input = BytesBuilder()
      ..add(utf8.encode('homelan-safety-v2'))
      ..add(sorted[0])
      ..add(sorted[1]);
    var digest = (await Sha256().hash(input.toBytes())).bytes;
    // Растягиваем до 30 байт (по 2,5 байта на группу из 5 цифр).
    digest = [...digest, ...(await Sha256().hash(digest)).bytes];
    final groups = <String>[];
    for (var i = 0; i < 12; i++) {
      final chunk = (digest[i * 2] << 16) | (digest[i * 2 + 1] << 8) | digest[i * 2 + 24];
      groups.add((chunk % 100000).toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }

  // ============ MESSAGES ============

  Future<SecretKey> _sharedKey(int myId, int peerId) async {
    if (!await loadIdentity()) throw CryptoException(S.current.noLocalKey);
    final status = peerStatus(peerId);
    final peer = _peerKeys[peerId];
    if (peer == null || status == PeerKeyStatus.mismatch) {
      throw CryptoException(status == PeerKeyStatus.mismatch ? S.current.peerKeyChanged : S.current.noPeerKey);
    }
    final cacheKey = '$myId:$peerId:${base64Encode(peer)}';
    final cached = _sharedKeys[cacheKey];
    if (cached != null) return cached;

    final shared = await _x25519.sharedSecretKey(
      keyPair: _identity!,
      remotePublicKey: SimplePublicKey(peer, type: KeyPairType.x25519),
    );
    final lo = myId < peerId ? myId : peerId;
    final hi = myId < peerId ? peerId : myId;
    final key = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('homelan-v2-salt'),
      info: utf8.encode('homelan/v2/msg/$lo/$hi'),
    );
    _sharedKeys[cacheKey] = key;
    return key;
  }

  static List<int> _aad(int senderId, int recipientId, String contentType, String clientId) =>
      utf8.encode('homelan/v2|$senderId|$recipientId|$contentType|$clientId');

  /// Шифрует сообщение от меня ([myId]) собеседнику ([peerId]).
  Future<Uint8List> encryptMessage({
    required Uint8List plaintext,
    required int myId,
    required int peerId,
    required String contentType,
    required String clientId,
  }) async {
    final key = await _sharedKey(myId, peerId);
    final nonce = _aead.newNonce();
    final box =
        await _aead.encrypt(plaintext, secretKey: key, nonce: nonce, aad: _aad(myId, peerId, contentType, clientId));
    final out = BytesBuilder(copy: false)
      ..addByte(kCryptoVersion)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Расшифровывает сообщение переписки с [peerId].
  Future<Uint8List> decryptMessage({
    required Uint8List blob,
    required int myId,
    required int peerId,
    required int senderId,
    required int recipientId,
    required String contentType,
    required String clientId,
  }) async {
    if (blob.length < 1 + 24 + 16 || blob[0] != kCryptoVersion) {
      throw CryptoException(S.current.unsupportedFormat);
    }
    final validPair = (senderId == myId && recipientId == peerId) || (senderId == peerId && recipientId == myId);
    if (!validPair) throw CryptoException(S.current.foreignMessage);
    final key = await _sharedKey(myId, peerId);
    final box = SecretBox(
      blob.sublist(25, blob.length - 16),
      nonce: blob.sublist(1, 25),
      mac: Mac(blob.sublist(blob.length - 16)),
    );
    try {
      final clear = await _aead.decrypt(box, secretKey: key, aad: _aad(senderId, recipientId, contentType, clientId));
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw CryptoException(S.current.tampered);
    }
  }

  /// Сбрасывает всё состояние в памяти (ключи в хранилище не трогает).
  void resetMemory() {
    _identity = null;
    _identityPub = null;
    _peerKeys.clear();
    _pendingPeerKeys.clear();
    _verified.clear();
    _sharedKeys.clear();
  }

  /// Полное удаление всех секретов этого приложения.
  Future<void> wipeAll() async {
    await _storage.deleteAll();
    resetMemory();
  }

  static int _compare(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Сравнение байтов за постоянное время.
  static bool equalBytes(Uint8List a, Uint8List b) => _equal(a, b);
}

// ============ LINKING (2-QR) ============

/// Эфемерная пара ключей для переноса identity-ключа на новое устройство.
class EphemeralKey {
  final Uint8List privateKey;
  final Uint8List publicKey;
  EphemeralKey(this.privateKey, this.publicKey);

  static Future<EphemeralKey> generate() async {
    final seed = Uint8List.fromList(SecretKeyData.random(length: 32).bytes);
    return EphemeralKey(seed, await CryptoService.publicFromPrivate(seed));
  }
}

/// Шифрование identity-ключа при привязке устройства.
class LinkCrypto {
  static final _x25519 = X25519();
  static final _aead = Xchacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Future<SecretKey> _key(Uint8List myPriv, Uint8List theirPub, String deviceId) async {
    final kp = await _x25519.newKeyPairFromSeed(myPriv);
    final shared = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: SimplePublicKey(theirPub, type: KeyPairType.x25519),
    );
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('homelan-v2-link'),
      info: utf8.encode('homelan/v2/link/$deviceId'),
    );
  }

  static List<int> _aad(String deviceId, String code) => utf8.encode('homelan/v2/link|$deviceId|$code');

  /// Старое устройство: шифрует identity-ключ для нового устройства.
  /// Возвращает (эфемерный публичный ключ старого устройства, шифротекст).
  static Future<(Uint8List, Uint8List)> seal({
    required Uint8List identityPrivate,
    required Uint8List newDevicePublic,
    required String deviceId,
    required String code,
  }) async {
    final eph = await EphemeralKey.generate();
    final key = await _key(eph.privateKey, newDevicePublic, deviceId);
    final nonce = _aead.newNonce();
    final box = await _aead.encrypt(identityPrivate, secretKey: key, nonce: nonce, aad: _aad(deviceId, code));
    final ct = BytesBuilder(copy: false)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return (eph.publicKey, ct.toBytes());
  }

  /// Новое устройство: расшифровывает identity-ключ.
  static Future<Uint8List> open({
    required Uint8List ephemeralPrivate,
    required Uint8List oldDevicePublic,
    required Uint8List ciphertext,
    required String deviceId,
    required String code,
  }) async {
    if (ciphertext.length != 24 + 32 + 16) throw CryptoException(S.current.linkDataCorrupt);
    final key = await _key(ephemeralPrivate, oldDevicePublic, deviceId);
    final box = SecretBox(ciphertext.sublist(24, ciphertext.length - 16),
        nonce: ciphertext.sublist(0, 24), mac: Mac(ciphertext.sublist(ciphertext.length - 16)));
    try {
      return Uint8List.fromList(await _aead.decrypt(box, secretKey: key, aad: _aad(deviceId, code)));
    } on SecretBoxAuthenticationError {
      throw CryptoException(S.current.linkWrongDevice);
    }
  }

  /// Короткий код сверки (6 цифр) по эфемерному ключу нового устройства —
  /// пользователь сравнивает его на обоих экранах.
  static Future<String> verificationCode(Uint8List ephemeralPublic) async {
    final h = (await Sha256().hash([...utf8.encode('homelan-v2-sas'), ...ephemeralPublic])).bytes;
    final n = ((h[0] << 16) | (h[1] << 8) | h[2]) % 1000000;
    final s = n.toString().padLeft(6, '0');
    return '${s.substring(0, 3)} ${s.substring(3)}';
  }
}
