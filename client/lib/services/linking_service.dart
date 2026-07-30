import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';

/// Данные для QR #1 (показывает новое устройство)
class DeviceLinkRequest {
  final String deviceId;
  final String deviceName;
  final String deviceType;
  final String? publicKey;

  DeviceLinkRequest({
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    this.publicKey,
  });

  String toJson() => jsonEncode({
    'type': 'link_request',
    'device_id': deviceId,
    'device_name': deviceName,
    'device_type': deviceType,
    if (publicKey != null) 'public_key': publicKey,
  });

  static DeviceLinkRequest? fromJson(String json) {
    try {
      final data = jsonDecode(json);
      if (data['type'] != 'link_request') return null;
      return DeviceLinkRequest(
        deviceId: data['device_id'],
        deviceName: data['device_name'],
        deviceType: data['device_type'],
        publicKey: data['public_key'],
      );
    } catch (e) {
      return null;
    }
  }
}

/// Данные для QR #2 (показывает старое устройство)
class DeviceLinkCode {
  final String code;

  DeviceLinkCode({required this.code});

  String toJson() => jsonEncode({
    'type': 'link_code',
    'code': code,
  });

  static DeviceLinkCode? fromJson(String json) {
    try {
      final data = jsonDecode(json);
      if (data['type'] != 'link_code') return null;
      return DeviceLinkCode(code: data['code']);
    } catch (e) {
      return null;
    }
  }
}

/// Сервис для работы с привязкой устройств
class LinkingService {
  /// Генерирует уникальный ID устройства
  static String generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).substring(0, 22);
  }

  /// Определяет тип устройства
  static String getDeviceType() {
    if (kIsWeb) return 'web';
    
    // Для мобильных/десктопов определяем по платформе
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'unknown';
    }
  }

  /// Получает имя устройства
  static Future<String> getDeviceName() async {
    // Можно использовать device_info_plus для реального имени
    // Пока возвращаем простое имя
    final type = getDeviceType();
    switch (type) {
      case 'android':
        return 'Android Phone';
      case 'ios':
        return 'iPhone';
      case 'windows':
        return 'Windows PC';
      case 'macos':
        return 'Mac';
      case 'linux':
        return 'Linux PC';
      default:
        return 'Unknown Device';
    }
  }
}