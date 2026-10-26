// lib/services/api_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'time_service.dart';

/// Ошибка, которую вернул сервер.
class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  ApiException(this.statusCode, this.code, this.message);

  bool get isUnauthorized => statusCode == 401;

  /// Человекочитаемое описание для UI.
  String get userMessage => _messages[code] ?? message;

  static const _messages = {
    'invalid_credentials': 'Неверный логин или пароль',
    'rate_limited': 'Слишком много попыток. Подождите и попробуйте снова',
    'device_not_linked': 'Это устройство не привязано к аккаунту. Привяжите его с уже подключённого устройства',
    'device_revoked': 'Это устройство отозвано',
    'user_limit': 'Достигнут лимит пользователей на сервере',
    'username_taken': 'Такой логин уже занят',
    'weak_password': 'Пароль должен быть не короче 8 символов',
    'invalid_username': 'Логин: 3–32 символа, буквы, цифры, «_», «.», «-»',
    'device_limit': 'Достигнут лимит устройств. Отзовите старое устройство',
    'invalid_link_code': 'Код привязки неверный или устарел',
    'file_too_large': 'Файл слишком большой для сервера',
    'quota_exceeded': 'Хранилище файлов на сервере заполнено',
    'disk_full': 'На сервере закончилось место',
    'unauthorized': 'Сессия недействительна, войдите снова',
  };

  @override
  String toString() => userMessage;
}

/// Сервер недоступен (нет сети, таймаут).
class NetworkException implements Exception {
  final Object cause;
  NetworkException(this.cause);
  @override
  String toString() => 'Сервер недоступен';
}

class ApiService {
  String baseUrl;
  String? token;
  final http.Client _client;

  static const _timeout = Duration(seconds: 15);

  ApiService({required this.baseUrl, this.token, http.Client? client}) : _client = client ?? http.Client();

  Map<String, String> _headers({bool json = false}) => {
        if (json) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() request) async {
    final http.Response resp;
    try {
      resp = await request().timeout(_timeout);
    } on SocketException catch (e) {
      throw NetworkException(e);
    } on TimeoutException catch (e) {
      throw NetworkException(e);
    } on http.ClientException catch (e) {
      throw NetworkException(e);
    } on HandshakeException catch (e) {
      throw NetworkException(e);
    }
    return _decode(resp.statusCode, resp.body);
  }

  Map<String, dynamic> _decode(int status, String body) {
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(body);
      data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      data = <String, dynamic>{};
    }
    if (status >= 200 && status < 300) {
      final serverTime = data['server_time'];
      if (serverTime is int) TimeService().syncFromServerResponse(serverTime);
      return data;
    }
    throw ApiException(
      status,
      data['error'] as String? ?? 'http_$status',
      data['message'] as String? ?? 'Ошибка сервера ($status)',
    );
  }

  Future<Map<String, dynamic>> _get(String path) => _send(() => _client.get(_uri(path), headers: _headers()));

  Future<Map<String, dynamic>> _post(String path, [Map<String, dynamic>? body]) =>
      _send(() => _client.post(_uri(path), headers: _headers(json: true), body: jsonEncode(body ?? {})));

  // ============ AUTH ============

  Future<Map<String, dynamic>> health() => _get('/health');

  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    required String deviceId,
    required String deviceName,
    required String deviceType,
    required Uint8List publicKey,
  }) =>
      _post('/api/register', {
        'username': username,
        'password': password,
        'device_id': deviceId,
        'device_name': deviceName,
        'device_type': deviceType,
        'public_key': base64Encode(publicKey),
      });

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    required String deviceId,
  }) =>
      _post('/api/login', {'username': username, 'password': password, 'device_id': deviceId});

  Future<void> logout() => _post('/api/logout');

  Future<Map<String, dynamic>> session() => _get('/api/session');

  /// Возвращает null, если собеседник ещё не зарегистрирован.
  Future<Map<String, dynamic>?> partner() async {
    try {
      final data = await _get('/api/partner');
      return data['partner'] as Map<String, dynamic>?;
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  // ============ DEVICES ============

  Future<Map<String, dynamic>> devices() => _get('/api/devices');

  Future<void> revokeDevice(String deviceId) => _post('/api/devices/revoke', {'device_id': deviceId});

  Future<Map<String, dynamic>> createLinkCode({
    required String deviceId,
    required String deviceName,
    required String deviceType,
  }) =>
      _post('/api/devices/link/create', {
        'device_id': deviceId,
        'device_name': deviceName,
        'device_type': deviceType,
      });

  Future<Map<String, dynamic>> completeLinking({required String linkCode, required String deviceId}) =>
      _post('/api/devices/link/complete', {'link_code': linkCode, 'device_id': deviceId});

  // ============ FILES ============

  /// Загружает уже зашифрованный файл потоком. Возвращает file_id.
  Future<String> uploadFile(String path, {void Function(double)? onProgress}) async {
    final file = File(path);
    final length = await file.length();
    final boundary = 'homelan-${DateTime.now().microsecondsSinceEpoch}';
    final head = utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="blob"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary--\r\n');

    var sent = 0;
    Stream<List<int>> body() async* {
      yield head;
      await for (final chunk in file.openRead()) {
        sent += chunk.length;
        onProgress?.call(sent / length);
        yield chunk;
      }
      yield tail;
    }

    final req = http.StreamedRequest('POST', _uri('/api/files/upload'))
      ..headers.addAll(_headers())
      ..headers['Content-Type'] = 'multipart/form-data; boundary=$boundary'
      ..contentLength = head.length + length + tail.length;

    final future = _client.send(req);
    body().listen(req.sink.add, onError: req.sink.addError, onDone: req.sink.close, cancelOnError: true);

    try {
      final resp = await future;
      final text = await resp.stream.bytesToString();
      final data = _decode(resp.statusCode, text);
      return data['file_id'] as String;
    } on SocketException catch (e) {
      throw NetworkException(e);
    } on http.ClientException catch (e) {
      throw NetworkException(e);
    }
  }

  /// Скачивает (зашифрованный) файл в [destPath] потоком.
  Future<void> downloadFile(String fileId, String destPath, {void Function(double)? onProgress}) async {
    final req = http.Request('GET', _uri('/api/files/$fileId'))..headers.addAll(_headers());
    final http.StreamedResponse resp;
    try {
      resp = await _client.send(req).timeout(_timeout);
    } on SocketException catch (e) {
      throw NetworkException(e);
    } on TimeoutException catch (e) {
      throw NetworkException(e);
    } on http.ClientException catch (e) {
      throw NetworkException(e);
    }
    if (resp.statusCode != 200) {
      _decode(resp.statusCode, await resp.stream.bytesToString());
    }
    final total = resp.contentLength ?? 0;
    final sink = File(destPath).openWrite();
    var received = 0;
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
    } catch (e) {
      await sink.close();
      await File(destPath).delete().catchError((_) => File(destPath));
      if (e is SocketException || e is http.ClientException) throw NetworkException(e);
      rethrow;
    }
    await sink.close();
  }
}
