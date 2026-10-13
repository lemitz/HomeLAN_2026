import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import '../utils/app_log.dart';

class BiometricService {
  static final BiometricService _instance = BiometricService._internal();
  factory BiometricService() => _instance;
  BiometricService._internal();

  final LocalAuthentication _auth = LocalAuthentication();

  bool _isAuthenticated = false;
  bool get isAuthenticated => _isAuthenticated;

  /// Текст последней ошибки для отображения на экране блокировки
  String? lastError;

  /// Доступна ли хоть какая-то защита (биометрия ИЛИ PIN/пароль устройства)
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (e) {
      return false;
    }
  }

  /// Запрашивает аутентификацию.
  ///
  /// Политика fail-closed: при ошибке пользователь остаётся на экране
  /// блокировки. Единственное исключение — на устройстве вообще не настроена
  /// защита (нет ни биометрии, ни PIN): защищать тогда нечем, и блокировка
  /// только мешала бы.
  Future<bool> authenticate() async {
    lastError = null;
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) {
        appLog('🔒 Device has no screen lock configured, skipping auth');
        _isAuthenticated = true;
        return true;
      }

      final result = await _auth.authenticate(
        localizedReason: 'Подтвердите личность для входа в HomeLAN',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // Разрешаем PIN/пароль как fallback
          useErrorDialogs: true,
        ),
      );

      _isAuthenticated = result;
      return result;
    } on PlatformException catch (e) {
      appLog('Biometric error: ${e.code}');
      switch (e.code) {
        case auth_error.notAvailable:
        case auth_error.notEnrolled:
        case auth_error.passcodeNotSet:
          // Защита на устройстве не настроена — пропускаем
          _isAuthenticated = true;
          return true;
        case auth_error.lockedOut:
          lastError = 'Слишком много попыток. Подождите и попробуйте снова.';
          break;
        case auth_error.permanentlyLockedOut:
          lastError = 'Биометрия заблокирована. Разблокируйте устройство PIN-кодом.';
          break;
        default:
          lastError = 'Не удалось подтвердить личность. Попробуйте ещё раз.';
      }
      _isAuthenticated = false;
      return false;
    } catch (e) {
      appLog('Biometric unexpected error: $e');
      lastError = 'Не удалось подтвердить личность. Попробуйте ещё раз.';
      _isAuthenticated = false;
      return false;
    }
  }

  /// Сбрасывает состояние (при сворачивании)
  void lock() {
    _isAuthenticated = false;
  }
}
