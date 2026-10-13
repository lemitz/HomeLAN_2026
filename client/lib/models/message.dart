import 'dart:convert';
import 'dart:typed_data';

class Message {
  final int? id;
  final int seqId;
  final int senderId;
  final int recipientId;
  final Uint8List encryptedContent;
  final String contentType;
  final String? fileId;
  final int createdAt;
  final int? expiresAt;
  final bool isDeleted;
  final String status;

  /// Локальный идентификатор исходящего сообщения до получения seq_id.
  /// Сервер возвращает его в `message_sent`, что позволяет однозначно
  /// сопоставить подтверждение с нужным сообщением. В БД не сохраняется.
  final String? clientId;

  Message({
    this.id,
    required this.seqId,
    required this.senderId,
    required this.recipientId,
    required this.encryptedContent,
    this.contentType = 'text',
    this.fileId,
    required this.createdAt,
    this.expiresAt,
    this.isDeleted = false,
    this.status = 'pending',
    this.clientId,
  });

  /// Сообщение зашифровано (единственный допустимый формат для отправки)
  bool get isEncrypted =>
      contentType == 'encrypted' || contentType.startsWith('encrypted_');

  bool get isFileMessage =>
      contentType.contains('file') || contentType.contains('image');

  String get textContent {
    try {
      return utf8.decode(encryptedContent);
    } catch (e) {
      return base64Encode(encryptedContent);
    }
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    Uint8List content;
    if (json['encrypted_content'] is String) {
      content = base64Decode(json['encrypted_content']);
    } else if (json['encrypted_content'] is List) {
      content = Uint8List.fromList(List<int>.from(json['encrypted_content']));
    } else {
      content = Uint8List(0);
    }

    return Message(
      id: json['id'],
      seqId: json['seq_id'] ?? 0,
      senderId: json['sender_id'] ?? 0,
      recipientId: json['recipient_id'] ?? 0,
      encryptedContent: content,
      contentType: json['content_type'] ?? 'text',
      fileId: json['file_id'],
      createdAt: json['created_at'] ?? 0,
      expiresAt: json['expires_at'],
      isDeleted: json['is_deleted'] == true || json['is_deleted'] == 1,
      status: json['status'] ?? 'sent',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'seq_id': seqId,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'encrypted_content': base64Encode(encryptedContent),
      'content_type': contentType,
      'file_id': fileId,
      'created_at': createdAt,
      'expires_at': expiresAt,
      'is_deleted': isDeleted,
      'status': status,
    };
  }

  Message copyWith({
    int? id,
    int? seqId,
    String? status,
    bool? isDeleted,
    int? createdAt,
  }) {
    return Message(
      id: id ?? this.id,
      seqId: seqId ?? this.seqId,
      senderId: senderId,
      recipientId: recipientId,
      encryptedContent: encryptedContent,
      contentType: contentType,
      fileId: fileId,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt,
      isDeleted: isDeleted ?? this.isDeleted,
      status: status ?? this.status,
      clientId: clientId,
    );
  }
}
