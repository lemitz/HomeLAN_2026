import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'time_service.dart';

/// REST-клиент сервера HomeLAN.
///
/// [baseUrl] можно менять на лету (экран входа / настройки / «сервер не найден»):
/// все запросы читают актуальное значение в момент вызова.
class ApiService {
  String baseUrl;
  String? token;

  /// Таймауты: без них запрос к выключенному серверу может висеть минутами.
  static const Duration _requestTimeout = Duration(seconds: 20);
  static const Duration _transferTimeout = Duration(minutes: 10);

  ApiService({required this.baseUrl, this.token});

  Map<String, String> _getHeaders() {
    final headers = <String, String>{};
    if (token != null) {
      headers['X-Session-Token'] = token!;
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Map<String, String> get _jsonHeaders => {
        'Content-Type': 'application/json',
        ..._getHeaders(),
      };

  Future<http.Response> _post(String path, Map<String, dynamic> body) {
    return http
        .post(
          Uri.parse('$baseUrl$path'),
          headers: _jsonHeaders,
          body: jsonEncode(body),
        )
        .timeout(_requestTimeout);
  }

  Future<http.Response> _get(String path) {
    return http
        .get(Uri.parse('$baseUrl$path'), headers: _getHeaders())
        .timeout(_requestTimeout);
  }

  Map<String, dynamic> _decodeAndSyncTime(http.Response response) {
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final serverTime = data['server_time'];
    if (serverTime is int && serverTime > 0) {
      TimeService().syncFromServerResponse(serverTime);
    }
    return data;
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    required String deviceId,
    required String deviceName,
    required String deviceType,
    Uint8List? publicKey,
  }) async {
    final body = <String, dynamic>{
      'username': username,
      'password': password,
      'device_id': deviceId,
      'device_name': deviceName,
      'device_type': deviceType,
    };
    if (publicKey != null) {
      body['public_key'] = base64Encode(publicKey);
    }

    final response = await _post('/api/register', body);
    if (response.statusCode == 200) {
      return _decodeAndSyncTime(response);
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    required String deviceId,
    String? deviceName,
    String? deviceType,
    Uint8List? publicKey,
  }) async {
    final body = <String, dynamic>{
      'username': username,
      'password': password,
      'device_id': deviceId,
    };
    if (deviceName != null) body['device_name'] = deviceName;
    if (deviceType != null) body['device_type'] = deviceType;
    if (publicKey != null) body['public_key'] = base64Encode(publicKey);

    final response = await _post('/api/login', body);
    if (response.statusCode == 200) {
      return _decodeAndSyncTime(response);
    }
    throw ApiException(response.statusCode, response.body);
  }

  /// Завершить сессию на сервере (токен становится недействительным,
  /// активное WebSocket-соединение этого устройства сервер закрывает сам).
  Future<void> logout() async {
    if (token == null) return;
    final response = await _post('/api/logout', const {});
    if (response.statusCode != 200 && response.statusCode != 401) {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Future<Map<String, dynamic>> getUser(int userId) async {
    final response = await _get('/api/user/$userId');
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> getHealth() async {
    final response = await _get('/health');
    if (response.statusCode == 200) {
      return _decodeAndSyncTime(response);
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<int> getServerTime() async {
    final response = await _get('/api/time');
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final serverTime = data['server_time'];
      if (serverTime is int && serverTime > 0) {
        TimeService().syncFromServerResponse(serverTime);
        return serverTime;
      }
    }
    return 0;
  }

  /// Получить собеседника (единственного другого юзера)
  Future<Map<String, dynamic>?> getPartner(int userId) async {
    final response = await _get('/api/partner');
    if (response.statusCode == 200) {
      return _decodeAndSyncTime(response);
    } else if (response.statusCode == 404) {
      return null; // Партнёр ещё не зарегистрирован
    }
    throw ApiException(response.statusCode, response.body);
  }

  // ============ FILE METHODS ============

  /// Загружает уже зашифрованное содержимое файла.
  ///
  /// Имя файла и MIME-тип на сервер НЕ передаются — они уходят собеседнику
  /// внутри зашифрованного сообщения.
  Future<Map<String, dynamic>> uploadFile({
    required int userId,
    required File file,
    required String fileName,
    required Uint8List encryptedData,
    String? mimeType,
    void Function(double progress)? onProgress,
  }) async {
    final uri = Uri.parse('$baseUrl/api/files/upload');

    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(_getHeaders());
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      encryptedData,
      filename: 'encrypted_file',
    ));

    final streamedResponse = await request.send().timeout(_transferTimeout);
    onProgress?.call(1.0);

    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Uint8List> downloadFile(String fileId) async {
    final response = await http
        .get(Uri.parse('$baseUrl/api/files/$fileId'), headers: _getHeaders())
        .timeout(_transferTimeout);

    if (response.statusCode == 200) {
      return response.bodyBytes;
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> getFileInfo(String fileId) async {
    final response = await _get('/api/files/$fileId/info');
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  // ============ DEVICE LINKING ============

  Future<Map<String, dynamic>> createLinkCode({
    required int userId,
    String? deviceId,
    String? deviceName,
    String? deviceType,
    Uint8List? publicKey,
  }) async {
    final body = <String, dynamic>{'user_id': userId};
    if (deviceId != null) body['device_id'] = deviceId;
    if (deviceName != null) body['device_name'] = deviceName;
    if (deviceType != null) body['device_type'] = deviceType;
    if (publicKey != null) body['public_key'] = base64Encode(publicKey);

    final response = await _post('/api/devices/link/create', body);
    if (response.statusCode == 200) {
      return _decodeAndSyncTime(response);
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> completeLinking({
    required String linkCode,
    required String deviceId,
    required String deviceName,
    required String deviceType,
    Uint8List? publicKey,
  }) async {
    final body = <String, dynamic>{
      'link_code': linkCode,
      'device_id': deviceId,
      'device_name': deviceName,
      'device_type': deviceType,
    };
    if (publicKey != null) {
      body['public_key'] = base64Encode(publicKey);
    }

    final response = await _post('/api/devices/link/complete', body);
    if (response.statusCode == 200) {
      return _decodeAndSyncTime(response);
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<List<Map<String, dynamic>>> getDevices(int userId) async {
    final response = await _get('/api/devices');
    if (response.statusCode == 200) {
      final data = _decodeAndSyncTime(response);
      return List<Map<String, dynamic>>.from(data['devices'] ?? []);
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<void> revokeDevice({
    required int userId,
    required String deviceId,
  }) async {
    final response = await _post('/api/devices/revoke', {
      'user_id': userId,
      'device_id': deviceId,
    });
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, response.body);
    }
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  /// Человекочитаемое описание для UI (без внутренних деталей сервера)
  String get userMessage {
    switch (statusCode) {
      case 401:
        return 'Неверное имя пользователя или пароль';
      case 403:
        return 'Доступ запрещён: ${message.trim()}';
      case 409:
        return 'Конфликт: ${message.trim()}';
      case 413:
        return 'Файл слишком большой';
      case 429:
        return 'Слишком много попыток. ${message.trim()}';
      case 507:
        return 'На сервере закончилось место для файлов';
      default:
        return 'Ошибка сервера ($statusCode): ${message.trim()}';
    }
  }

  @override
  String toString() => 'ApiException: [$statusCode] $message';
}
