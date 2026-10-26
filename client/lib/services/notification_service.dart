import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../l10n/strings.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  // Callback когда юзер нажал на уведомление
  Function(int? userId)? onNotificationTap;

  /// Локальные уведомления есть только на мобильных платформах.
  bool get _supported => Platform.isAndroid || Platform.isIOS;

  Future<void> init() async {
    if (_isInitialized || !_supported) return;

    // Android настройки
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    // iOS настройки (на всякий случай)
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    // Запрашиваем разрешение на Android 13+
    if (Platform.isAndroid) {
      await _requestPermissions();
    }

    // Создаём канал уведомлений для Android
    await _createNotificationChannel();

    _isInitialized = true;
    debugPrint('🔔 NotificationService initialized');
  }

  Future<void> _requestPermissions() async {
    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
    }
  }

  Future<void> _createNotificationChannel() async {
    final channel = AndroidNotificationChannel(
      'homelan_messages',
      S.current.notifChannel,
      description: S.current.notifChannelDesc,
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(channel);
  }

  void _onNotificationTap(NotificationResponse response) {
    debugPrint('🔔 Notification tapped: ${response.payload}');

    if (response.payload != null) {
      try {
        final userId = int.tryParse(response.payload!);
        onNotificationTap?.call(userId);
      } catch (e) {
        debugPrint('Error parsing notification payload: $e');
      }
    }
  }

  /// Показать уведомление о новом сообщении
  Future<void> showMessageNotification({
    required int senderId,
    required String senderName,
    required String messageText,
    bool isImage = false,
    bool isFile = false,
  }) async {
    if (!_supported) return;
    if (!_isInitialized) await init();

    String body = messageText;
    if (isImage) {
      body = S.current.photo;
    } else if (isFile) {
      body = S.current.fileNotification;
    } else if (messageText.length > 100) {
      body = '${messageText.substring(0, 100)}...';
    }

    final androidDetails = AndroidNotificationDetails(
      'homelan_messages',
      S.current.notifChannel,
      channelDescription: S.current.notifChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      when: DateTime.now().millisecondsSinceEpoch,
      icon: '@mipmap/ic_launcher',
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: senderName,
        summaryText: 'HomeLAN',
      ),
      category: AndroidNotificationCategory.message,
      visibility: NotificationVisibility.private,
      autoCancel: true,
      playSound: true,
      enableVibration: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Используем senderId как ID уведомления (группировка по отправителю)
    await _notifications.show(
      senderId,
      senderName,
      body,
      details,
      payload: senderId.toString(),
    );

    debugPrint('🔔 Notification shown: $senderName - $body');
  }

  /// Убрать уведомления от конкретного юзера (когда открыли чат)
  Future<void> cancelNotificationsFromUser(int userId) async {
    if (!_isInitialized) return;
    await _notifications.cancel(userId);
  }

  /// Убрать все уведомления
  Future<void> cancelAll() async {
    if (!_isInitialized) return;
    await _notifications.cancelAll();
  }
}
