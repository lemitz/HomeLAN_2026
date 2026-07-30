import 'message.dart';

class Chat {
  final int oderId;
  final String username;
  final Message? lastMessage;
  final int unreadCount;

  Chat({
    required this.oderId,
    required this.username,
    this.lastMessage,
    this.unreadCount = 0,
  });
}