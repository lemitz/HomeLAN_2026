class User {
  final int id;
  final String username;
  final bool isAdmin;
  final int createdAt;
  final int lastSeen;

  User({
    required this.id,
    required this.username,
    this.isAdmin = false,
    required this.createdAt,
    required this.lastSeen,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] ?? json['user_id'] ?? 0,
      username: json['username'] ?? '',
      isAdmin: json['is_admin'] ?? false,
      createdAt: json['created_at'] ?? 0,
      lastSeen: json['last_seen'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'is_admin': isAdmin,
      'created_at': createdAt,
      'last_seen': lastSeen,
    };
  }
}