// lib/providers/auth_provider.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../services/services.dart';
import '../services/foreground_service.dart';
import '../utils/app_log.dart';

/// Минимальная длина пароля (совпадает с требованием сервера)
const int minPasswordLength = 8;

/// Результат проверки сохранённой сессии при старте
enum SessionCheck {
  /// Сервер подтвердил сессию
  valid,

  /// Сервер ответил 401: токен истёк/отозван — нужен повторный вход,
  /// ключи устройства и локальная история сохраняются
  expired,

  /// Сервер ответил 403: устройство отозвано — локальные данные уничтожаются
  revoked,

  /// Сервер недоступен — работаем офлайн с локальными данными
  offline,
}

class AuthProvider with ChangeNotifier {
  final ApiService _api;
  final WebSocketService _ws;
  final DatabaseService _db;
  final CryptoService _crypto;

  int? _userId;
  String? _username;
  String? _deviceId;
  bool _isAdmin = false;
  bool _isLoading = false;
  String? _error;
  bool _sessionInvalid = false;
  bool _offline = false;
  bool _validating = false;

  int? _partnerId;
  String? _partnerUsername;

  int? get userId => _userId;
  String? get username => _username;
  String? get deviceId => _deviceId;
  bool get isAdmin => _isAdmin;
  bool get isLoading => _isLoading;
  bool get isLoggedIn => _userId != null && !_sessionInvalid;
  String? get error => _error;
  bool get sessionInvalid => _sessionInvalid;
  bool get isOffline => _offline;
  CryptoService get crypto => _crypto;
  ApiService get apiService => _api;

  int? get partnerId => _partnerId;
  String? get partnerUsername => _partnerUsername;
  bool get hasPartner => _partnerId != null && _partnerId! > 0;

  AuthProvider({
    required ApiService api,
    required WebSocketService ws,
    required DatabaseService db,
    required CryptoService crypto,
  })  : _api = api,
        _ws = ws,
        _db = db,
        _crypto = crypto {
    _ws.onPersistentFailure = _onWsPersistentFailure;
  }

  Future<void> init() async {
    await _crypto.init();
    await ForegroundService().init();

    _api.token = await _crypto.getSessionToken();

    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getInt('user_id');
    _username = prefs.getString('username');
    _deviceId = prefs.getString('device_id');
    _isAdmin = prefs.getBool('is_admin') ?? false;
    _partnerId = prefs.getInt('partner_id');
    _partnerUsername = prefs.getString('partner_username');

    if (_deviceId == null) {
      _deviceId = const Uuid().v4();
      await prefs.setString('device_id', _deviceId!);
    }

    if (_userId != null && _api.token != null) {
      await _loadCachedPartnerKey();
      await _handleSessionCheck(await _validateSession());
    } else if (_userId != null) {
      // Сессии нет (например, после logout на старой версии) — нужен вход
      await _softLogout();
    }

    notifyListeners();
  }

  /// Проверяет сессию через REST и классифицирует результат.
  Future<SessionCheck> _validateSession() async {
    if (_userId == null) return SessionCheck.expired;

    try {
      final userData = await _api.getUser(_userId!);
      if (userData['id'] == _userId) {
        return SessionCheck.valid;
      }
      return SessionCheck.expired;
    } on ApiException catch (e) {
      appLog('Session validation: HTTP ${e.statusCode}');
      if (e.statusCode == 403) return SessionCheck.revoked;
      if (e.statusCode == 401) return SessionCheck.expired;
      // 5xx и прочее — считаем временной проблемой сервера
      return SessionCheck.offline;
    } catch (e) {
      // SocketException, TimeoutException и т.п.
      appLog('Session validation: network error: $e');
      return SessionCheck.offline;
    }
  }

  Future<void> _handleSessionCheck(SessionCheck check) async {
    switch (check) {
      case SessionCheck.valid:
        _offline = false;
        await _connectWebSocket();
        await _refreshPartner();
        break;
      case SessionCheck.offline:
        // Сервер недоступен: не разлогиниваем и тем более не стираем данные.
        // Показываем локальную историю, WebSocket сам переподключится.
        _offline = true;
        await _connectWebSocket();
        break;
      case SessionCheck.expired:
        appLog('⚠️ Session expired, re-login required');
        await _softLogout();
        break;
      case SessionCheck.revoked:
        appLog('🚫 Device revoked by server, wiping local data');
        _sessionInvalid = true;
        await fullWipe();
        break;
    }
  }

  /// Повторная проверка сессии (вызывается при проблемах с WebSocket и
  /// вручную из UI). Безопасна при параллельных вызовах.
  Future<void> revalidateSession() async {
    if (_userId == null || _validating) return;
    _validating = true;
    try {
      final check = await _validateSession();
      if (check == SessionCheck.valid && _offline) {
        _offline = false;
        await _refreshPartner();
        notifyListeners();
      } else if (check == SessionCheck.expired || check == SessionCheck.revoked) {
        await _handleSessionCheck(check);
        notifyListeners();
      }
    } finally {
      _validating = false;
    }
  }

  void _onWsPersistentFailure(int failures) {
    // WebSocket не может подключиться несколько раз подряд: возможно, токен
    // отозван (сервер отвечает 401/403 на upgrade). Уточняем через REST.
    revalidateSession();
  }

  /// Подхватываем сохранённый ключ партнёра, чтобы офлайн-режим мог
  /// расшифровывать историю без обращения к серверу.
  Future<void> _loadCachedPartnerKey() async {
    if (_partnerId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('partner_public_key');
    if (cached != null && cached.isNotEmpty) {
      try {
        _crypto.setUserPublicKeyBase64(_partnerId!, cached);
      } catch (e) {
        appLog('Bad cached partner key: $e');
      }
    }
  }

  Future<void> _refreshPartner() async {
    if (_userId == null) return;

    try {
      final partner = await _api.getPartner(_userId!);
      if (partner != null) {
        _partnerId = partner['id'];
        _partnerUsername = partner['username'];

        final prefs = await SharedPreferences.getInstance();

        if (partner['public_key'] != null) {
          final publicKeyBase64 = partner['public_key'] as String;
          _crypto.setUserPublicKeyBase64(_partnerId!, publicKeyBase64);
          await prefs.setString('partner_public_key', publicKeyBase64);
        }

        await prefs.setInt('partner_id', _partnerId!);
        await prefs.setString('partner_username', _partnerUsername!);
      }
    } catch (e) {
      appLog('⚠️ Failed to get partner: $e');
    }
  }

  String? validatePassword(String password) {
    if (password.length < minPasswordLength) {
      return 'Пароль должен быть не короче $minPasswordLength символов';
    }
    // bcrypt на сервере учитывает не более 72 БАЙТ (кириллица — 2 байта/символ)
    if (utf8.encode(password).length > 72) {
      return 'Пароль слишком длинный (максимум 72 байта в UTF-8)';
    }
    return null;
  }

  Future<bool> register(String username, String password) async {
    final passwordError = validatePassword(password);
    if (passwordError != null) {
      _error = passwordError;
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _error = null;
    _sessionInvalid = false;
    notifyListeners();

    try {
      final deviceName = Platform.localHostname;
      final deviceType = Platform.operatingSystem;
      final publicKey = await _crypto.getPublicKey();

      final result = await _api.register(
        username: username,
        password: password,
        deviceId: _deviceId!,
        deviceName: deviceName,
        deviceType: deviceType,
        publicKey: publicKey,
      );

      _userId = result['user_id'];
      _username = username;
      _isAdmin = result['is_admin'] ?? false;

      final token = result['token'] as String?;
      if (token != null) {
        await _crypto.saveSessionToken(token);
        _api.token = token;
      }

      await _saveSession();
      await _connectWebSocket();
      await _refreshPartner();

      _offline = false;
      _isLoading = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _error = e.userMessage;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _error = 'Сервер недоступен: ${_api.baseUrl}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> login(String username, String password) async {
    _isLoading = true;
    _error = null;
    _sessionInvalid = false;
    notifyListeners();

    try {
      final publicKey = await _crypto.getPublicKey();

      final result = await _api.login(
        username: username,
        password: password,
        deviceId: _deviceId!,
        deviceName: Platform.localHostname,
        deviceType: Platform.operatingSystem,
        publicKey: publicKey,
      );

      _userId = result['user_id'];
      _username = username;
      _isAdmin = result['is_admin'] ?? false;

      final token = result['token'] as String?;
      if (token != null) {
        await _crypto.saveSessionToken(token);
        _api.token = token;
      }

      // Партнёр приходит сразу с логина
      if (result['partner_id'] != null && result['partner_id'] > 0) {
        _partnerId = result['partner_id'];
        _partnerUsername = result['partner_username'];

        if (result['partner_public_key'] != null) {
          final key = result['partner_public_key'] as String;
          _crypto.setUserPublicKeyBase64(_partnerId!, key);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('partner_public_key', key);
        }
      }

      await _saveSession();
      await _connectWebSocket();

      // Если ключ не пришёл с логина — получаем отдельно
      if (_partnerId != null && !_crypto.hasUserPublicKey(_partnerId!)) {
        await _refreshPartner();
      }

      _offline = false;
      _isLoading = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _error = e.userMessage;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _error = 'Сервер недоступен: ${_api.baseUrl}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> completeDeviceLinking({
    required int userId,
    required String username,
    required String deviceId,
    String? token,
  }) async {
    _userId = userId;
    _username = username;
    _deviceId = deviceId;
    _sessionInvalid = false;

    if (token != null) {
      await _crypto.saveSessionToken(token);
      _api.token = token;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_id', deviceId);

    await _saveSession();
    await _connectWebSocket();
    await _refreshPartner();

    _offline = false;
    notifyListeners();
  }

  /// Выход: завершает сессию на сервере и забывает её локально.
  ///
  /// Ключевая пара устройства и локальная история НЕ удаляются — иначе после
  /// повторного входа старые сообщения невозможно расшифровать. Полная очистка —
  /// это [fullWipe] (отзыв устройства или явное решение пользователя).
  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (e) {
      appLog('Server logout failed (continuing locally): $e');
    }
    await _softLogout();
    notifyListeners();
  }

  Future<void> _softLogout() async {
    await ForegroundService().stop();
    await _ws.disconnect();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_id');
    await prefs.remove('username');
    await prefs.remove('is_admin');
    await prefs.remove('partner_id');
    await prefs.remove('partner_username');

    await _crypto.clearSessionToken();
    _api.token = null;

    _userId = null;
    _username = null;
    _isAdmin = false;
    _partnerId = null;
    _partnerUsername = null;
    _sessionInvalid = false;
    _offline = false;
  }

  /// Полное уничтожение локальных данных: ключи, токен, история, настройки.
  Future<void> fullWipe() async {
    appLog('🗑️ Starting full wipe...');

    await ForegroundService().stop();
    await _ws.disconnect();

    final prefs = await SharedPreferences.getInstance();
    final serverUrl = prefs.getString('server_url');
    await prefs.clear();
    // device_id генерируется заново: старый отозван на сервере
    if (serverUrl != null) {
      await prefs.setString('server_url', serverUrl);
    }
    _deviceId = const Uuid().v4();
    await prefs.setString('device_id', _deviceId!);

    await _crypto.clearKeys();
    await _db.clearAll();
    _api.token = null;

    _userId = null;
    _username = null;
    _isAdmin = false;
    _partnerId = null;
    _partnerUsername = null;
    _sessionInvalid = false;
    _offline = false;
    _error = null;

    notifyListeners();
  }

  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('user_id', _userId!);
    await prefs.setString('username', _username!);
    await prefs.setBool('is_admin', _isAdmin);
    if (_partnerId != null) {
      await prefs.setInt('partner_id', _partnerId!);
    }
    if (_partnerUsername != null) {
      await prefs.setString('partner_username', _partnerUsername!);
    }
  }

  Future<void> _connectWebSocket() async {
    if (_userId != null && _deviceId != null) {
      final token = await _crypto.getSessionToken();
      if (token == null) return;
      await _ws.connect(
        userId: _userId!,
        deviceId: _deviceId!,
        token: token,
      );
      await ForegroundService().start();
    }
  }

  /// Адрес сервера изменён пользователем: переподключаем WebSocket и
  /// перепроверяем сессию по новому адресу.
  Future<void> onServerUrlChanged() async {
    if (_userId == null) return;
    await _ws.reconnectNow();
    await revalidateSession();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
