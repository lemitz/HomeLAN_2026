// lib/services/biometric_service.dart
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import '../l10n/strings.dart';

enum UnlockResult {
  /// Пользователь подтвердил личность.
  success,

  /// Пользователь отменил или проверка не прошла — остаёмся заблокированными.
  failed,

  /// На устройстве вообще не настроена блокировка (нет PIN/биометрии).
  notAvailable,
}

/// Блокировка приложения биометрией или PIN-кодом устройства.
/// Принцип fail-closed: любая ошибка оставляет приложение заблокированным.
class BiometricService {
  static final BiometricService _instance = BiometricService._internal();
  factory BiometricService() => _instance;
  BiometricService._internal();

  final LocalAuthentication _auth = LocalAuthentication();

  int _suspendDepth = 0;

  /// true, пока открыт системный пикер/камера — уход в фон не блокирует приложение.
  bool get isSuspended => _suspendDepth > 0;

  /// Выполняет [action] (например, выбор файла), не блокируя приложение при
  /// временном уходе в фон.
  Future<T> withoutLock<T>(Future<T> Function() action) async {
    _suspendDepth++;
    try {
      return await action();
    } finally {
      // Даём жизненному циклу вернуться в resumed до снятия флага.
      Future.delayed(const Duration(milliseconds: 800), () => _suspendDepth--);
    }
  }

  Future<UnlockResult> authenticate() async {
    try {
      if (!await _auth.isDeviceSupported()) return UnlockResult.notAvailable;
      final ok = await _auth.authenticate(
        localizedReason: S.current.unlockReason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // PIN/пароль устройства как запасной вариант
          useErrorDialogs: true,
        ),
      );
      return ok ? UnlockResult.success : UnlockResult.failed;
    } catch (e) {
      debugPrint('Biometric error: $e');
      return UnlockResult.failed;
    }
  }
}
