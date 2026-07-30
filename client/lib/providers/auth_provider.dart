// lib/providers/auth_provider.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../services/services.dart';
import '../services/foreground_service.dart';

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
        _crypto = crypto;

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

    if (_userId != null && _deviceId != null) {
      final isValid = await _validateSession();
      if (isValid) {
        await _connectWebSocket();
        await _refreshPartner();
      } else {
        print('⚠️ Session invalid, forcing logout');
        _sessionInvalid = true;
        await fullWipe();
      }
    }

    notifyListeners();
  }

  Future<bool> _validateSession() async {
    if (_userId == null) return false;
    
    try {
      final userData = await _api.getUser(_userId!);
      if (userData['id'] == _userId) {
        print('✅ Session valid for user $_userId');
        return true;
      }
      return false;
    } catch (e) {
      print('❌ Session validation failed: $e');
      return false;
    }
  }

  // ИСПРАВЛЕНО: Получаем и сохраняем публичный ключ партнёра
  Future<void> _refreshPartner() async {
    if (_userId == null) return;
    
    try {
      final partner = await _api.getPartner(_userId!);
      if (partner != null) {
        _partnerId = partner['id'];
        _partnerUsername = partner['username'];
        
        // ВАЖНО: Сохраняем публичный ключ партнёра!
        if (partner['public_key'] != null) {
          final publicKeyBase64 = partner['public_key'] as String;
          _crypto.setUserPublicKeyBase64(_partnerId!, publicKeyBase64);
          print('🔐 Loaded partner public key for user $_partnerId');
        }
        
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('partner_id', _partnerId!);
        await prefs.setString('partner_username', _partnerUsername!);
        
        print('👥 Partner: $_partnerUsername (ID: $_partnerId)');
      }
    } catch (e) {
      print('⚠️ Failed to get partner: $e');
    }
  }

  Future<bool> register(String username, String password) async {
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

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
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
        
        // ВАЖНО: Сохраняем публичный ключ партнёра если есть
        if (result['partner_public_key'] != null) {
          _crypto.setUserPublicKeyBase64(_partnerId!, result['partner_public_key']);
          print('🔐 Loaded partner public key from login');
        }
      }

      await _saveSession();
      await _connectWebSocket();
      
      // Если ключ не пришёл с логина — получаем отдельно
      if (_partnerId != null && !_crypto.hasUserPublicKey(_partnerId!)) {
        await _refreshPartner();
      }

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
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
    
    print('🔐 Device linked successfully: $username (ID: $userId)');
    notifyListeners();
  }

  Future<void> logout() async {
    await ForegroundService().stop();
    _ws.disconnect();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_id');
    await prefs.remove('username');
    await prefs.remove('is_admin');
    await prefs.remove('partner_id');
    await prefs.remove('partner_username');

    await _crypto.clearKeys();
    _api.token = null;

    _userId = null;
    _username = null;
    _isAdmin = false;
    _partnerId = null;
    _partnerUsername = null;
    _sessionInvalid = false;

    notifyListeners();
  }

  Future<void> fullWipe() async {
    print('🗑️ Starting full wipe...');
    
    await ForegroundService().stop();
    _ws.disconnect();

    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString('device_id');
    await prefs.clear();
    if (deviceId != null) {
      await prefs.setString('device_id', deviceId);
    }

    await _crypto.clearKeys();
    await _db.clearAll();
    _api.token = null;

    _userId = null;
    _username = null;
    _isAdmin = false;
    _partnerId = null;
    _partnerUsername = null;
    _sessionInvalid = false;
    _error = null;

    print('✅ Full wipe complete');
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
      final token = await _crypto.getSessionToken() ?? 'temp_token';
      await _ws.connect(
        userId: _userId!,
        deviceId: _deviceId!,
        token: token,
      );
      await ForegroundService().start();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}