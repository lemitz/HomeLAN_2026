import 'package:flutter/material.dart';
import '../models/models.dart';

class ChatTile extends StatelessWidget {
  final int userId;
  final String username;
  final Message? lastMessage;
  final int unreadCount;
  final VoidCallback onTap;

  const ChatTile({
    super.key,
    required this.userId,
    required this.username,
    this.lastMessage,
    this.unreadCount = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary изолирует перерисовку этого виджета от остального списка
    return RepaintBoundary(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: Colors.blue[700],
          child: Text(
            username.isNotEmpty ? username[0].toUpperCase() : '?',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          username,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 16,
            color: Colors.white, // Явно задаем цвет для контраста на темном фоне
          ),
        ),
        subtitle: lastMessage != null
            ? Text(
                lastMessage!.textContent,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 14,
                ),
              )
            : null,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (lastMessage != null)
              Text(
                _formatTime(lastMessage!.createdAt),
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 12,
                ),
              ),
            if (unreadCount > 0) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue[600],
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  unreadCount > 99 ? '99+' : unreadCount.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    
    if (date.day == now.day && date.month == now.month && date.year == now.year) {
      final hour = date.hour.toString().padLeft(2, '0');
      final minute = date.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } else {
      return '${date.day}.${date.month}';
    }
  }
}