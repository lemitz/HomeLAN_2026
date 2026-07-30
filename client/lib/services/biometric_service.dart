import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class BiometricService {
  static final BiometricService _instance = BiometricService._internal();
  factory BiometricService() => _instance;
  BiometricService._internal();

  final LocalAuthentication _auth = LocalAuthentication();
  
  bool _isAuthenticated = false;
  bool get isAuthenticated => _isAuthenticated;

  /// Проверяет, доступна ли биометрия
  Future<bool> isAvailable() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      return canCheck && isSupported;
    } catch (e) {
      return false;
    }
  }

  /// Запрашивает аутентификацию
  Future<bool> authenticate() async {
    try {
      final available = await isAvailable();
      if (!available) {
        // Если биометрия недоступна — пропускаем (для эмуляторов/старых устройств)
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
      print('Biometric error: $e');
      // При ошибке разрешаем вход (чтобы не заблокировать)
      _isAuthenticated = true;
      return true;
    }
  }

  /// Сбрасывает состояние (при сворачивании)
  void lock() {
    _isAuthenticated = false;
  }
}