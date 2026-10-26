// lib/providers/auth_provider.dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/services.dart';

enum AuthStatus { loading, loggedOut, loggedIn }

/// Аккаунт, сессия и ключи этого устройства.
///
/// Правила:
/// * Сетевая ошибка никогда не разлогинивает и ничего не стирает —
///   приложение просто работает офлайн.
/// * Выход (logout) отзывает сессию, но сохраняет identity-ключ и device_id:
///   повторный вход по паролю на этом устройстве вернёт доступ к истории.
/// * Новое устройство подключается только через привязку (linking).
/// * Полная очистка удаляет всё, включая ключ, и отзывает устройство.
class AuthProvider with ChangeNotifier {
  final ApiService _api;
  final WebSocketService _ws;
  final DatabaseService _db;
  final CryptoService _crypto;

  AuthProvider({
    required ApiService api,
    required WebSocketService ws,
    required DatabaseService db,
    required CryptoService crypto,
  })  : _api = api,
        _ws = ws,
        _db = db,
        _crypto = crypto {
    _ws.onUnauthorized = _onSessionRejected;
  }

  AuthStatus _status = AuthStatus.loading;
  UserInfo? _user;
  UserInfo? _partner;
  String? _deviceId;
  bool _isBusy = false;
  String? _error;
  String? _notice;
  PeerKeyStatus _partnerKeyStatus = PeerKeyStatus.unknown;

  AuthStatus get status => _status;
  bool get isLoggedIn => _status == AuthStatus.loggedIn;
  bool get isBusy => _isBusy;
  String? get error => _error;

  /// Сообщение для экрана входа (например, «сессия истекла»).
  String? get notice => _notice;

  int? get userId => _user?.id;
  String? get username => _user?.username;
  bool get isAdmin => _user?.isAdmin ?? false;
  String? get deviceId => _deviceId;
  UserInfo? get partner => _partner;
  int? get partnerId => _partner?.id;
  String? get partnerUsername => _partner?.username;
  bool get hasPartner => _partner != null;
  PeerKeyStatus get partnerKeyStatus => _partnerKeyStatus;
  ApiService get api => _api;
  CryptoService get crypto => _crypto;

  /// Можно ли отправлять сообщения собеседнику.
  bool get canEncrypt => _partnerKeyStatus == PeerKeyStatus.trusted || _partnerKeyStatus == PeerKeyStatus.verified;

  // ============ STARTUP ============

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString('device_id_v2');
    final token = await _crypto.readToken();
    final hasIdentity = await _crypto.loadIdentity();
    final cachedUser = _decodeUser(prefs.getString('user_v2'));

    if (token == null || !hasIdentity || cachedUser == null || _deviceId == null) {
      _setStatus(AuthStatus.loggedOut);
      return;
    }

    // Входим сразу из кеша — приложение работает и без сервера.
    _api.token = token;
    _user = cachedUser;
    _partner = _decodeUser(prefs.getString('partner_v2'));
    if (_partner != null) {
      await _crypto.loadPinnedPeer(_partner!.id);
      _partnerKeyStatus = _crypto.peerStatus(_partner!.id);
      if (_partnerKeyStatus == PeerKeyStatus.unknown) {
        _partnerKeyStatus = await _crypto.registerPeerKey(_partner!.id, _partner!.publicKey);
      }
    }
    _setStatus(AuthStatus.loggedIn);
    _ws.start(token);
    ForegroundService().start();
    refreshSession();
  }

  /// Проверяет сессию на сервере и обновляет данные собеседника.
  /// 401 — разлогиниваем (ключ сохраняется), сетевые ошибки игнорируем.
  Future<void> refreshSession() async {
    if (!isLoggedIn) return;
    try {
      final data = await _api.session();
      await _applySession(data, saveToken: false);
    } on ApiException catch (e) {
      if (e.isUnauthorized) await _onSessionRejected();
    } on NetworkException {
      // Офлайн — работаем с кешем.
    } catch (e) {
      debugPrint('refreshSession: $e');
    }
  }

  Future<void> _onSessionRejected() async {
    if (!isLoggedIn) return;
    await _endSession(notice: 'Сессия недействительна. Войдите снова');
  }

  // ============ REGISTER / LOGIN / LINK ============

  Future<bool> register(String username, String password) => _guard(() async {
        // Новый аккаунт — новое устройство и новый identity-ключ. Старые
        // ключи заменяются только после успешного ответа сервера.
        final deviceId = DeviceInfo.newDeviceId();
        final identity = await EphemeralKey.generate();
        final data = await _api.register(
          username: username,
          password: password,
          deviceId: deviceId,
          deviceName: DeviceInfo.name(),
          deviceType: DeviceInfo.type(),
          publicKey: identity.publicKey,
        );
        await _replaceIdentity(identity.privateKey, identity.publicKey);
        await _saveDeviceId(deviceId);
        await _applySession(data, saveToken: true);
      });

  Future<bool> login(String username, String password) => _guard(() async {
        if (_deviceId == null || !await _crypto.loadIdentity()) {
          throw const _UserError('На этом устройстве нет ключа шифрования. '
              'Привяжите устройство с уже подключённого («Привязать к аккаунту»)');
        }
        final data = await _api.login(username: username, password: password, deviceId: _deviceId!);
        await _applySession(data, saveToken: true);
      });

  /// Завершение привязки: [identityPrivate] получен из QR#2.
  Future<bool> completeLinking({
    required String deviceId,
    required String linkCode,
    required Uint8List identityPrivate,
  }) =>
      _guard(() async {
        final data = await _api.completeLinking(linkCode: linkCode, deviceId: deviceId);
        final user = UserInfo.fromJson(data['user']);
        if (user == null) throw const _UserError('Некорректный ответ сервера');
        final pub = await CryptoService.publicFromPrivate(identityPrivate);
        if (!CryptoService.equalBytes(pub, user.publicKey)) {
          // Ключ не совпал с ключом аккаунта — сессию на сервере сразу закрываем.
          _api.token = data['token'] as String?;
          try {
            await _api.revokeDevice(deviceId);
          } catch (_) {}
          _api.token = null;
          throw const _UserError('Полученный ключ не совпадает с ключом аккаунта. Привязка отменена');
        }
        await _replaceIdentity(identityPrivate, pub);
        await _saveDeviceId(deviceId);
        await _applySession(data, saveToken: true);
      });

  /// Заменяет все секреты устройства новым identity-ключом.
  /// Ключ сохраняется первым: аккаунт на сервере уже создан, и потеря ключа
  /// из-за ошибки локальной БД сделала бы его непригодным.
  Future<void> _replaceIdentity(Uint8List priv, Uint8List pub) async {
    await _crypto.wipeAll();
    await _crypto.importIdentity(priv, expectedPublic: pub);
    try {
      await _db.clearAll();
    } catch (e) {
      debugPrint('clear local cache failed: $e');
    }
  }

  Future<void> _applySession(Map<String, dynamic> data, {required bool saveToken}) async {
    final user = UserInfo.fromJson(data['user']);
    if (user == null) throw const _UserError('Некорректный ответ сервера');

    // Ключ аккаунта на сервере обязан совпадать с ключом устройства.
    final myPub = await _crypto.identityPublicKey();
    if (!CryptoService.equalBytes(myPub, user.publicKey)) {
      throw const _UserError('Ключ шифрования устройства не совпадает с ключом аккаунта на сервере. '
          'Возможна подмена сервера. Вход остановлен');
    }

    if (saveToken) {
      final token = data['token'] as String?;
      if (token == null) throw const _UserError('Сервер не выдал токен');
      await _crypto.saveToken(token);
      _api.token = token;
    }
    _user = user;
    _notice = null;

    final partner = UserInfo.fromJson(data['partner']);
    if (partner != null) {
      _partner = partner;
      _partnerKeyStatus = await _crypto.registerPeerKey(partner.id, partner.publicKey);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_v2', jsonEncode(user.toJson()));
    if (_partner != null) await prefs.setString('partner_v2', jsonEncode(_partner!.toJson()));

    if (_status != AuthStatus.loggedIn) {
      _setStatus(AuthStatus.loggedIn);
      _ws.start(_api.token!);
      ForegroundService().start();
    } else {
      notifyListeners();
    }
  }

  /// Проверяет, не появился ли собеседник (экран ожидания).
  Future<void> refreshPartner() async {
    if (!isLoggedIn) return;
    try {
      final p = UserInfo.fromJson(await _api.partner());
      if (p == null) return;
      _partner = p;
      _partnerKeyStatus = await _crypto.registerPeerKey(p.id, p.publicKey);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('partner_v2', jsonEncode(p.toJson()));
      notifyListeners();
    } on ApiException catch (e) {
      if (e.isUnauthorized) await _onSessionRejected();
    } on NetworkException {
      // офлайн
    }
  }

  // ============ PARTNER KEY ============

  Future<String?> safetyNumber() async {
    final p = _partner;
    if (p == null) return null;
    final peerKey = _crypto.pendingPeerKey(p.id) ?? _crypto.peerKey(p.id);
    if (peerKey == null) return null;
    return CryptoService.safetyNumber(await _crypto.identityPublicKey(), peerKey);
  }

  Future<void> markPartnerVerified() async {
    final p = _partner;
    if (p == null) return;
    if (_partnerKeyStatus == PeerKeyStatus.mismatch) {
      await _crypto.acceptPendingPeerKey(p.id);
    }
    await _crypto.setVerified(p.id, true);
    _partnerKeyStatus = _crypto.peerStatus(p.id);
    notifyListeners();
  }

  // ============ LOGOUT / WIPE ============

  /// Выход: сессия отзывается, кеш сообщений очищается,
  /// identity-ключ и device_id остаются на устройстве.
  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (_) {}
    await _endSession();
  }

  Future<void> _endSession({String? notice}) async {
    _ws.stop();
    await ForegroundService().stop();
    await _crypto.clearToken();
    _api.token = null;
    await _db.clearMessages();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_v2');
    await prefs.remove('partner_v2');
    _user = null;
    _partner = null;
    _partnerKeyStatus = PeerKeyStatus.unknown;
    _notice = notice;
    _setStatus(AuthStatus.loggedOut);
  }

  /// Полная очистка: отзыв устройства на сервере (если доступен) и удаление
  /// всех ключей, токенов и кеша. Устройство придётся привязывать заново.
  Future<void> fullWipe() async {
    if (_deviceId != null && _api.token != null) {
      try {
        await _api.revokeDevice(_deviceId!);
      } catch (_) {}
    }
    _ws.stop();
    await ForegroundService().stop();
    await _crypto.wipeAll();
    await _db.clearAll();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    _api.token = null;
    _deviceId = null;
    _user = null;
    _partner = null;
    _partnerKeyStatus = PeerKeyStatus.unknown;
    _notice = null;
    _setStatus(AuthStatus.loggedOut);
  }

  // ============ HELPERS ============

  Future<bool> _guard(Future<void> Function() action) async {
    _isBusy = true;
    _error = null;
    notifyListeners();
    try {
      await action();
      return true;
    } on ApiException catch (e) {
      _error = e.userMessage;
    } on NetworkException {
      _error = 'Сервер недоступен. Проверьте подключение к домашней сети';
    } on _UserError catch (e) {
      _error = e.message;
    } on CryptoException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Ошибка: $e';
    } finally {
      _isBusy = false;
      notifyListeners();
    }
    return false;
  }

  Future<void> _saveDeviceId(String id) async {
    _deviceId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_id_v2', id);
  }

  UserInfo? _decodeUser(String? json) {
    if (json == null) return null;
    try {
      return UserInfo.fromJson(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }

  void _setStatus(AuthStatus s) {
    _status = s;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}

class _UserError implements Exception {
  final String message;
  const _UserError(this.message);
}
