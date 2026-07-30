import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CryptoService {
  static const String _privateKeyKey = 'private_key';
  static const String _publicKeyKey = 'public_key';
  static const String _sessionTokenKey = 'session_token';
  
  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  
  final X25519 _keyExchange = X25519();
  final Chacha20 _cipher = Chacha20.poly1305Aead();
  
  SimpleKeyPair? _keyPair;
  final Map<int, SimplePublicKey> _publicKeys = {};

  /// Инициализация — загружаем или генерируем ключи
  Future<void> init() async {
    // 1. Try reading from SecureStorage
    String? privateKeyBase64 = await _secureStorage.read(key: _privateKeyKey);
    String? publicKeyBase64 = await _secureStorage.read(key: _publicKeyKey);

    // 2. Migration from SharedPreferences if not in SecureStorage
    if (privateKeyBase64 == null) {
      final prefs = await SharedPreferences.getInstance();
      privateKeyBase64 = prefs.getString(_privateKeyKey);
      publicKeyBase64 = prefs.getString(_publicKeyKey);

      if (privateKeyBase64 != null && publicKeyBase64 != null) {
        // Save to SecureStorage
        await _secureStorage.write(key: _privateKeyKey, value: privateKeyBase64);
        await _secureStorage.write(key: _publicKeyKey, value: publicKeyBase64);
        
        // Remove from SharedPreferences
        await prefs.remove(_privateKeyKey);
        await prefs.remove(_publicKeyKey);
        print('🔐 Migrated key pair to secure storage and deleted from SharedPreferences');
      }
    }

    if (privateKeyBase64 != null && publicKeyBase64 != null) {
      final privateKeyBytes = base64Decode(privateKeyBase64);
      final publicKeyBytes = base64Decode(publicKeyBase64);
      
      _keyPair = SimpleKeyPairData(
        privateKeyBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
      print('🔐 Loaded existing key pair from secure storage');
    } else {
      await generateKeyPair();
    }
  }

  /// Генерация новой пары ключей
  Future<void> generateKeyPair() async {
    final keyData = await compute(_generateKeyPairIsolate, null);
    
    _keyPair = SimpleKeyPairData(
      keyData['private']!,
      publicKey: SimplePublicKey(keyData['public']!, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    
    final privateKeyBase64 = base64Encode(keyData['private']!);
    final publicKeyBase64 = base64Encode(keyData['public']!);

    await _secureStorage.write(key: _privateKeyKey, value: privateKeyBase64);
    await _secureStorage.write(key: _publicKeyKey, value: publicKeyBase64);
    
    // Ensure we delete any legacy keys in shared preferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_privateKeyKey);
    await prefs.remove(_publicKeyKey);

    print('🔐 Generated and saved new key pair in secure storage');
  }

  static Future<Map<String, Uint8List>> _generateKeyPairIsolate(void _) async {
    final keyExchange = X25519();
    final keyPair = await keyExchange.newKeyPair();
    
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    
    return {
      'private': Uint8List.fromList(privateKeyBytes),
      'public': Uint8List.fromList(publicKey.bytes),
    };
  }

  /// Получить свой публичный ключ
  Future<Uint8List> getPublicKey() async {
    if (_keyPair == null) await init();
    final publicKey = await _keyPair!.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  /// Получить публичный ключ в base64
  Future<String> getPublicKeyBase64() async {
    final publicKey = await getPublicKey();
    return base64Encode(publicKey);
  }

  // ============ ЭКСПОРТ/ИМПОРТ КЛЮЧЕЙ ДЛЯ DEVICE LINKING ============

  /// Экспортирует ключевую пару в base64 строку (для передачи на новое устройство)
  Future<String> exportKeyPair() async {
    if (_keyPair == null) await init();
    
    final privateKeyBytes = await _keyPair!.extractPrivateKeyBytes();
    final publicKey = await _keyPair!.extractPublicKey();
    
    final exportData = {
      'private': base64Encode(Uint8List.fromList(privateKeyBytes)),
      'public': base64Encode(Uint8List.fromList(publicKey.bytes)),
    };
    
    return base64Encode(utf8.encode(jsonEncode(exportData)));
  }

  /// Импортирует ключевую пару из base64 строки (на новом устройстве)
  Future<void> importKeyPair(String exportedData) async {
    try {
      final jsonStr = utf8.decode(base64Decode(exportedData));
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      
      final privateKeyBytes = base64Decode(data['private'] as String);
      final publicKeyBytes = base64Decode(data['public'] as String);
      
      _keyPair = SimpleKeyPairData(
        privateKeyBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
      
      // Сохраняем импортированные ключи в SecureStorage
      await _secureStorage.write(key: _privateKeyKey, value: data['private'] as String);
      await _secureStorage.write(key: _publicKeyKey, value: data['public'] as String);
      
      // Удаляем из SharedPreferences на всякий случай
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_privateKeyKey);
      await prefs.remove(_publicKeyKey);
      
      print('🔐 Imported key pair successfully into secure storage');
    } catch (e) {
      print('🔐 Failed to import key pair: $e');
      rethrow;
    }
  }

  /// Проверяет, есть ли ключи
  Future<bool> hasKeys() async {
    String? privateKey = await _secureStorage.read(key: _privateKeyKey);
    if (privateKey != null) return true;

    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_privateKeyKey) != null;
  }

  // ============ СЕССИОННЫЕ ТОКЕНЫ ============

  Future<void> saveSessionToken(String token) async {
    await _secureStorage.write(key: _sessionTokenKey, value: token);
  }

  Future<String?> getSessionToken() async {
    // Check secure storage first
    String? token = await _secureStorage.read(key: _sessionTokenKey);
    if (token != null) return token;

    // Check SharedPreferences for migration
    final prefs = await SharedPreferences.getInstance();
    token = prefs.getString(_sessionTokenKey);
    if (token != null) {
      // Migrate to secure storage
      await _secureStorage.write(key: _sessionTokenKey, value: token);
      await prefs.remove(_sessionTokenKey);
      print('🔐 Migrated session token to secure storage');
    }
    return token;
  }

  Future<void> clearSessionToken() async {
    await _secureStorage.delete(key: _sessionTokenKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionTokenKey);
  }

  // ============ ПУБЛИЧНЫЕ КЛЮЧИ ДРУГИХ ЮЗЕРОВ ============

  void setUserPublicKey(int userId, Uint8List publicKeyBytes) {
    _publicKeys[userId] = SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519);
    print('🔐 Stored public key for user $userId');
  }

  void setUserPublicKeyBase64(int userId, String publicKeyBase64) {
    final bytes = base64Decode(publicKeyBase64);
    setUserPublicKey(userId, Uint8List.fromList(bytes));
  }

  bool hasUserPublicKey(int userId) {
    return _publicKeys.containsKey(userId);
  }

  // ============ ШИФРОВАНИЕ ============

  Future<Uint8List> encrypt(String plaintext, int recipientId) async {
    final plaintextBytes = utf8.encode(plaintext);
    return await encryptBytes(Uint8List.fromList(plaintextBytes), recipientId);
  }

  Future<String> decrypt(Uint8List encryptedData, int senderId) async {
    final decryptedBytes = await decryptBytes(encryptedData, senderId);
    return utf8.decode(decryptedBytes);
  }

  Future<Uint8List> encryptBytes(Uint8List plainBytes, int recipientId) async {
    if (_keyPair == null) await init();
    
    final recipientPublicKey = _publicKeys[recipientId];
    if (recipientPublicKey == null) {
      throw Exception('No public key for user $recipientId');
    }

    final sharedSecret = await _keyExchange.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: recipientPublicKey,
    );

    final nonce = _cipher.newNonce();

    final secretBox = await _cipher.encrypt(
      plainBytes,
      secretKey: sharedSecret,
      nonce: nonce,
    );

    final result = Uint8List(nonce.length + secretBox.cipherText.length + secretBox.mac.bytes.length);
    result.setAll(0, nonce);
    result.setAll(nonce.length, secretBox.cipherText);
    result.setAll(nonce.length + secretBox.cipherText.length, secretBox.mac.bytes);

    return result;
  }

  Future<Uint8List> decryptBytes(Uint8List encryptedData, int senderId) async {
    if (_keyPair == null) await init();

    final senderPublicKey = _publicKeys[senderId];
    if (senderPublicKey == null) {
      throw Exception('No public key for user $senderId');
    }

    final sharedSecret = await _keyExchange.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: senderPublicKey,
    );

    const nonceLength = 12;
    const macLength = 16;
    
    if (encryptedData.length < nonceLength + macLength) {
      throw Exception('Invalid encrypted data: too short');
    }

    final nonce = encryptedData.sublist(0, nonceLength);
    final cipherText = encryptedData.sublist(nonceLength, encryptedData.length - macLength);
    final macBytes = encryptedData.sublist(encryptedData.length - macLength);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final decrypted = await _cipher.decrypt(
      secretBox,
      secretKey: sharedSecret,
    );

    return Uint8List.fromList(decrypted);
  }

  Future<void> clearKeys() async {
    await _secureStorage.delete(key: _privateKeyKey);
    await _secureStorage.delete(key: _publicKeyKey);
    await clearSessionToken();
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_privateKeyKey);
    await prefs.remove(_publicKeyKey);
    
    _keyPair = null;
    _publicKeys.clear();
    print('🔐 Cleared all keys from secure storage and preferences');
  }
}
