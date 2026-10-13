/// Нормализация адреса сервера, введённого пользователем.
///
/// Принимает `192.168.1.10`, `192.168.1.10:8080`, `http://host:8080/`,
/// `orangepi.local` и т.п. Возвращает `http://host:port` без завершающего `/`
/// или `null`, если адрес невалиден.
String? normalizeServerUrl(String input, {int defaultPort = 8080}) {
  var value = input.trim();
  if (value.isEmpty) return null;

  if (!value.contains('://')) {
    value = 'http://$value';
  }

  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.userInfo.isNotEmpty) return null;

  final port = uri.hasPort ? uri.port : defaultPort;
  if (port < 1 || port > 65535) return null;

  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return '${uri.scheme}://$host:$port';
}

/// Короткое отображение адреса для UI (без схемы).
String displayServerUrl(String url) {
  return url.replaceFirst(RegExp(r'^https?://'), '');
}
