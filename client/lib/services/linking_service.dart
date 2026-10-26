// lib/services/linking_service.dart
//
// Форматы данных для привязки устройства (2-QR + текстовый fallback).
//
// QR#1 (новое устройство → старое): device_id, имя, тип, эфемерный ключ.
// QR#2 (старое → новое): код привязки + identity-ключ, зашифрованный
//       эфемерным ключом нового устройства. Сервер ключ не видит.
//
// Текстовый вид — то же содержимое: "HL1:" / "HL2:" + base64url(JSON).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class LinkRequest {
  final String deviceId;
  final String deviceName;
  final String deviceType;
  final Uint8List ephemeralPublic;

  LinkRequest({
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    required this.ephemeralPublic,
  });

  String encode() => 'HL1:${base64Url.encode(utf8.encode(jsonEncode({
            'v': 2,
            'd': deviceId,
            'n': deviceName,
            't': deviceType,
            'k': base64Encode(ephemeralPublic),
          })))}';

  static LinkRequest? tryParse(String input) {
    final data = _decode(input, 'HL1:');
    if (data == null || data['v'] != 2) return null;
    try {
      final key = base64Decode(data['k'] as String);
      if (key.length != 32) return null;
      return LinkRequest(
        deviceId: data['d'] as String,
        deviceName: data['n'] as String? ?? '',
        deviceType: data['t'] as String,
        ephemeralPublic: key,
      );
    } catch (_) {
      return null;
    }
  }
}

class LinkResponse {
  final String code;
  final Uint8List ephemeralPublic;
  final Uint8List ciphertext;

  LinkResponse({required this.code, required this.ephemeralPublic, required this.ciphertext});

  String encode() => 'HL2:${base64Url.encode(utf8.encode(jsonEncode({
            'v': 2,
            'c': code,
            'k': base64Encode(ephemeralPublic),
            'e': base64Encode(ciphertext),
          })))}';

  static LinkResponse? tryParse(String input) {
    final data = _decode(input, 'HL2:');
    if (data == null || data['v'] != 2) return null;
    try {
      return LinkResponse(
        code: data['c'] as String,
        ephemeralPublic: base64Decode(data['k'] as String),
        ciphertext: base64Decode(data['e'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

Map<String, dynamic>? _decode(String input, String prefix) {
  final s = input.replaceAll(RegExp(r'\s'), '');
  if (!s.startsWith(prefix)) return null;
  try {
    final json = utf8.decode(base64Url.decode(base64Url.normalize(s.substring(prefix.length))));
    final data = jsonDecode(json);
    return data is Map<String, dynamic> ? data : null;
  } catch (_) {
    return null;
  }
}

class DeviceInfo {
  /// Случайный идентификатор устройства (22 символа base64url, 128 бит).
  static String newDeviceId() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String type() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'linux';
  }

  static String name() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty && host != 'localhost') {
        return host.length > 64 ? host.substring(0, 64) : host;
      }
    } catch (_) {}
    switch (type()) {
      case 'android':
        return 'Android';
      case 'windows':
        return 'Windows PC';
      default:
        return type();
    }
  }
}
