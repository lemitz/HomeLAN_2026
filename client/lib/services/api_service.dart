import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'time_service.dart';

class ApiService {
  final String baseUrl;
  
  ApiService({required this.baseUrl});

  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    required String deviceId,
    required String deviceName,
    required String deviceType,
    Uint8List? publicKey,
  }) async {
    final body = {
      'username': username,
      'password': password,
      'device_id': deviceId,
      'device_name': deviceName,
      'device_type': deviceType,
    };
    
    if (publicKey != null) {
      body['public_key'] = base64Encode(publicKey);
    }

    final response = await http.post(
      Uri.parse('$baseUrl/api/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      
      if (data['server_time'] != null) {
        TimeService().syncFromServerResponse(data['server_time']);
      }
      
      return data;
    } else {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    required String deviceId,
    Uint8List? publicKey,
  }) async {
    final body = {
      'username': username,
      'password': password,
      'device_id': deviceId,
    };
    
    if (publicKey != null) {
      body['public_key'] = base64Encode(publicKey);
    }

    final response = await http.post(
      Uri.parse('$baseUrl/api/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      
      if (data['server_time'] != null) {
        TimeService().syncFromServerResponse(data['server_time']);
      }
      
      return data;
    } else {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Future<Map<String, dynamic>> getUser(int userId) async {
    final response = await http.get(Uri.parse('$baseUrl/api/user/$userId'));
    
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Future<Map<String, dynamic>> getHealth() async {
    final response = await http.get(Uri.parse('$baseUrl/health'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      
      if (data['server_time'] != null) {
        TimeService().syncFromServerResponse(data['server_time']);
      }
      
      return data;
    } else {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Future<int> getServerTime() async {
    final response = await http.get(Uri.parse('$baseUrl/api/time'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final serverTime = data['server_time'] ?? 0;
      
      if (serverTime > 0) {
        TimeService().syncFromServerResponse(serverTime);
      }
      
      return serverTime;
    }
    return 0;
  }
  
  /// Получить собеседника (единственного другого юзера)
  Future<Map<String, dynamic>?> getPartner(int userId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/partner?user_id=$userId'),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['server_time'] != null) {
        TimeService().syncFromServerResponse(data['server_time']);
      }
      return data;
    } else if (response.statusCode == 404) {
      return null; // Партнёр ещё не зарегистрирован
    } else {
      throw ApiException(response.statusCode, response.body);
    }
  }

  // ============ FILE METHODS ============

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
    
    request.fields['user_id'] = userId.toString();
    request.fields['file_name'] = base64Encode(utf8.encode(fileName));
    request.fields['mime_type'] = mimeType ?? 'application/octet-stream';
    request.fields['original_size'] = encryptedData.length.toString();
    
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      encryptedData,
      filename: 'encrypted_file',
    ));

    final streamedResponse = await request.send();
    
    onProgress?.call(1.0);
    
    final response = await http.Response.fromStream(streamedResponse);
    
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Future<Uint8List> downloadFile(String fileId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/files/$fileId'),
    );
    
    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Future<Map<String, dynamic>> getFileInfo(String fileId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/files/$fileId/info'),
    );
    
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw ApiException(response.statusCode, response.body);
    }
  }

  // ============ DEVICE LINKING ============

  Future<Map<String, dynamic>> createLinkCode({
    required int userId,
    String? deviceId,      // Сделали опциональным
    String? deviceName,    // Сделали опциональным
    String? deviceType,    // Сделали опциональным
    Uint8List? publicKey,
  }) async {
    final body = <String, dynamic>{
      'user_id': userId,
    };

    // Добавляем только если есть значения
    if (deviceId != null) body['device_id'] = deviceId;
    if (deviceName != null) body['device_name'] = deviceName;
    if (deviceType != null) body['device_type'] = deviceType;
    if (publicKey != null) body['public_key'] = base64Encode(publicKey);

    final response = await http.post(
      Uri.parse('$baseUrl/api/devices/link/create'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['server_time'] != null) {
        TimeService().syncFromServerResponse(data['server_time']);
      }
      return data;
    } else {
      throw ApiException(response.statusCode, response.body);
    }
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

    final response = await http.post(
      Uri.parse('$baseUrl/api/devices/link/complete'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['server_time'] != null) {
        TimeService().syncFromServerResponse(data['server_time']);
      }
      return data;
    } else {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Future<List<Map<String, dynamic>>> getDevices(int userId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/devices?user_id=$userId'),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['server_time'] != null) {
        TimeService().syncFromServerResponse(data['server_time']);
      }
      return List<Map<String, dynamic>>.from(data['devices'] ?? []);
    } else {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Future<void> revokeDevice({
    required int userId,
    required String deviceId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/devices/revoke'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'user_id': userId,
        'device_id': deviceId,
      }),
    );

    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, response.body);
    }
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}