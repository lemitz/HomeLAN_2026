import 'package:flutter/foundation.dart';

/// Логирование только в debug-сборках.
///
/// В release-сборке ничего не выводится: раньше `print` писал в системный лог
/// (logcat / stdout) идентификаторы пользователей, адреса сервера, содержимое
/// расшифрованных уведомлений и т.п., доступные другим приложениям/пользователям ПК.
void appLog(Object? message) {
  if (kDebugMode) {
    debugPrint('$message');
  }
}
