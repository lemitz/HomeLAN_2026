// lib/services/server_config.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_log.dart';
import '../utils/server_url.dart';
import 'mdns_service.dart';

/// Адрес по умолчанию — только подсказка для первого запуска.
const String defaultServerUrl = 'http://192.168.100.100:8080';

/// Единая точка хранения адреса сервера.
///
/// Правила:
///  * сохранённый адрес НИКОГДА не подменяется автоматически результатом mDNS —
///    иначе любое устройство в сети, объявившее `_homelan._tcp`, могло бы увести
///    клиента на себя при недоступности настоящего сервера;
///  * mDNS используется один раз при первом запуске (когда адрес ещё не задан)
///    и по явному нажатию пользователя «Найти в сети»;
///  * смена адреса применяется ко всем сервисам через [onChanged].
class ServerConfig {
  static final ServerConfig _instance = ServerConfig._internal();
  factory ServerConfig() => _instance;
  ServerConfig._internal();

  static const String _prefsKey = 'server_url';

  /// Текущий адрес вида `http://host:port`. UI может подписаться на изменения.
  final ValueNotifier<String> url = ValueNotifier<String>(defaultServerUrl);

  bool _configured = false;

  /// Адрес задан пользователем или найден через mDNS (а не значение по умолчанию)
  bool get isConfigured => _configured;

  String get current => url.value;

  /// Хук, который main.dart подключает к ApiService/WebSocketService/ConnectionService
  Future<void> Function(String url)? onChanged;

  /// Загружает адрес при старте. Если он не сохранён — один раз пробует mDNS.
  Future<String> load() async {
    final prefs = await SharedPreferences.getInstance();

    final saved = prefs.getString(_prefsKey);
    final normalizedSaved = saved == null ? null : normalizeServerUrl(saved);
    if (normalizedSaved != null) {
      url.value = normalizedSaved;
      _configured = true;
      return normalizedSaved;
    }

    appLog('📡 No saved server URL, trying mDNS once...');
    final discovered = await MDNSService.discoverServer();
    if (discovered != null) {
      url.value = discovered;
      _configured = true;
      await prefs.setString(_prefsKey, discovered);
      return discovered;
    }

    // Не сохраняем значение по умолчанию: пользователь должен ввести адрес сам
    url.value = defaultServerUrl;
    _configured = false;
    return defaultServerUrl;
  }

  /// Сохраняет и применяет новый адрес. Возвращает false, если адрес невалиден.
  Future<bool> apply(String input) async {
    final normalized = normalizeServerUrl(input);
    if (normalized == null) return false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, normalized);
    _configured = true;

    final changed = url.value != normalized;
    url.value = normalized;
    if (changed || onChanged != null) {
      await onChanged?.call(normalized);
    }
    return true;
  }

  /// Явный поиск сервера в сети (по кнопке пользователя). Ничего не сохраняет.
  Future<String?> discover({Duration timeout = const Duration(seconds: 5)}) {
    return MDNSService.discoverServer(timeout: timeout);
  }

  /// Проверка доступности адреса (GET /health)
  Future<bool> check(String input) async {
    final normalized = normalizeServerUrl(input);
    if (normalized == null) return false;
    return MDNSService.checkServer(normalized);
  }
}
