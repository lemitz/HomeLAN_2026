import 'dart:convert';
import 'dart:typed_data';

/// Локальный статус исходящего сообщения (до подтверждения сервером).
enum LocalStatus { pending, sent, failed }

/// Статус для отображения галочек.
enum DeliveryStatus { pending, failed, sent, delivered, read }

/// Сообщение в том виде, в каком его хранит сервер (содержимое зашифровано).
///
/// [clientId] вместе с [senderId] однозначно идентифицирует сообщение ещё до
/// того, как сервер выдаст [seqId]. [changeSeq] — номер последнего изменения
/// на сервере (используется для синхронизации).
class Message {
  final int? localId;
  final String clientId;
  final int? seqId;
  final int changeSeq;
  final int senderId;
  final int recipientId;
  final String contentType; // text | image | file
  final Uint8List encryptedContent;
  final String? fileId;
  final int createdAt;
  final int? expiresAt;
  final int? deliveredAt;
  final int? readAt;
  final bool isDeleted;
  final LocalStatus localStatus;
  final String? failReason;

  const Message({
    this.localId,
    required this.clientId,
    this.seqId,
    this.changeSeq = 0,
    required this.senderId,
    required this.recipientId,
    required this.contentType,
    required this.encryptedContent,
    this.fileId,
    required this.createdAt,
    this.expiresAt,
    this.deliveredAt,
    this.readAt,
    this.isDeleted = false,
    this.localStatus = LocalStatus.sent,
    this.failReason,
  });

  bool get isFile => contentType == 'file' || contentType == 'image';
  bool get isImage => contentType == 'image';

  /// Ключ сообщения, стабильный до и после подтверждения сервером.
  String get key => '$senderId:$clientId';

  DeliveryStatus get deliveryStatus {
    if (localStatus == LocalStatus.failed) return DeliveryStatus.failed;
    if (seqId == null || localStatus == LocalStatus.pending) return DeliveryStatus.pending;
    if (readAt != null) return DeliveryStatus.read;
    if (deliveredAt != null) return DeliveryStatus.delivered;
    return DeliveryStatus.sent;
  }

  static int? _int(dynamic v) {
    if (v == null) return null;
    if (v is int) return v == 0 ? null : v;
    if (v is num) return v.toInt() == 0 ? null : v.toInt();
    return null;
  }

  /// Из сообщения сервера (WebSocket).
  factory Message.fromServer(Map<String, dynamic> json) {
    final raw = json['encrypted_content'];
    return Message(
      clientId: json['client_id'] as String? ?? '',
      seqId: json['seq_id'] as int?,
      changeSeq: json['change_seq'] as int? ?? 0,
      senderId: json['sender_id'] as int,
      recipientId: json['recipient_id'] as int,
      contentType: json['content_type'] as String? ?? 'text',
      encryptedContent: raw is String && raw.isNotEmpty ? base64Decode(raw) : Uint8List(0),
      fileId: (json['file_id'] as String?)?.isEmpty == true ? null : json['file_id'] as String?,
      createdAt: json['created_at'] as int? ?? 0,
      expiresAt: _int(json['expires_at']),
      deliveredAt: _int(json['delivered_at']),
      readAt: _int(json['read_at']),
      isDeleted: json['is_deleted'] == true,
      localStatus: LocalStatus.sent,
    );
  }

  /// Из строки локальной БД.
  factory Message.fromDb(Map<String, dynamic> row) {
    final content = row['encrypted_content'];
    return Message(
      localId: row['local_id'] as int?,
      clientId: row['client_id'] as String,
      seqId: row['seq_id'] as int?,
      changeSeq: row['change_seq'] as int? ?? 0,
      senderId: row['sender_id'] as int,
      recipientId: row['recipient_id'] as int,
      contentType: row['content_type'] as String,
      encryptedContent: content is Uint8List
          ? content
          : content is List
              ? Uint8List.fromList(List<int>.from(content))
              : Uint8List(0),
      fileId: row['file_id'] as String?,
      createdAt: row['created_at'] as int,
      expiresAt: row['expires_at'] as int?,
      deliveredAt: row['delivered_at'] as int?,
      readAt: row['read_at'] as int?,
      isDeleted: row['is_deleted'] == 1,
      localStatus: LocalStatus.values.byName(row['local_status'] as String? ?? 'sent'),
      failReason: row['fail_reason'] as String?,
    );
  }

  Map<String, dynamic> toDb() => {
        'client_id': clientId,
        'seq_id': seqId,
        'change_seq': changeSeq,
        'sender_id': senderId,
        'recipient_id': recipientId,
        'content_type': contentType,
        'encrypted_content': encryptedContent,
        'file_id': fileId,
        'created_at': createdAt,
        'expires_at': expiresAt,
        'delivered_at': deliveredAt,
        'read_at': readAt,
        'is_deleted': isDeleted ? 1 : 0,
        'local_status': localStatus.name,
        'fail_reason': failReason,
      };

  Message copyWith({
    int? localId,
    LocalStatus? localStatus,
    String? failReason,
    int? createdAt,
  }) {
    return Message(
      localId: localId ?? this.localId,
      clientId: clientId,
      seqId: seqId,
      changeSeq: changeSeq,
      senderId: senderId,
      recipientId: recipientId,
      contentType: contentType,
      encryptedContent: encryptedContent,
      fileId: fileId,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt,
      deliveredAt: deliveredAt,
      readAt: readAt,
      isDeleted: isDeleted,
      localStatus: localStatus ?? this.localStatus,
      failReason: failReason,
    );
  }
}

/// Расшифрованное содержимое сообщения (только в памяти, на диск не пишется).
class DecryptedContent {
  final String? text;
  final FileMeta? file;
  final String? error;

  const DecryptedContent.text(this.text)
      : file = null,
        error = null;
  const DecryptedContent.file(this.file)
      : text = null,
        error = null;
  const DecryptedContent.error(this.error)
      : text = null,
        file = null;

  bool get isError => error != null;
}

/// Метаданные файла внутри зашифрованного сообщения.
class FileMeta {
  final String name;
  final int size;
  final String mime;
  final Uint8List key; // ключ шифрования содержимого файла

  const FileMeta({required this.name, required this.size, required this.mime, required this.key});

  Map<String, dynamic> toJson() => {'name': name, 'size': size, 'mime': mime, 'key': base64Encode(key)};

  factory FileMeta.fromJson(Map<String, dynamic> json) => FileMeta(
        name: json['name'] as String,
        size: json['size'] as int,
        mime: json['mime'] as String? ?? 'application/octet-stream',
        key: base64Decode(json['key'] as String),
      );
}
