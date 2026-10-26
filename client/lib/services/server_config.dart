// lib/services/server_config.dart
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/strings.dart';

import 'mdns_service.dart';

/// Адрес сервера: сохранённый → найденный через mDNS → по умолчанию.
class ServerConfig {
  static const defaultUrl = 'http://192.168.100.100:8080';
  static const _key = 'server_url';

  static Future<String> resolve() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null && await MDNSService.checkServer(saved)) return saved;

    final discovered = await MDNSService.discoverServer();
    if (discovered != null) {
      await prefs.setString(_key, discovered);
      return discovered;
    }
    return saved ?? defaultUrl;
  }

  /// Нормализует и сохраняет адрес, введённый пользователем.
  static Future<String> save(String input) async {
    var url = input.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) url = 'http://$url';
    url = url.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse(url);
    if (uri.host.isEmpty) throw FormatException(S.current.invalidAddress);
    if (!uri.hasPort) url = '$url:8080';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, url);
    return url;
  }
}
