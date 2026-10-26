import 'dart:convert';
import 'dart:typed_data';

/// Пользователь в том виде, в каком его отдаёт сервер.
class UserInfo {
  final int id;
  final String username;
  final bool isAdmin;
  final Uint8List publicKey; // identity-ключ X25519

  const UserInfo({
    required this.id,
    required this.username,
    required this.isAdmin,
    required this.publicKey,
  });

  static UserInfo? fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    final key = json['public_key'];
    return UserInfo(
      id: json['id'] as int,
      username: json['username'] as String? ?? '',
      isAdmin: json['is_admin'] == true,
      publicKey: key is String ? base64Decode(key) : Uint8List(0),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'is_admin': isAdmin,
        'public_key': base64Encode(publicKey),
      };
}
