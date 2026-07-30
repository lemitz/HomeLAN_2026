import 'dart:io';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class ForegroundService {
  static final ForegroundService _instance = ForegroundService._internal();
  factory ForegroundService() => _instance;
  ForegroundService._internal();

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  /// Инициализация сервиса
  Future<void> init() async {
    if (!Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'homelan_foreground',
        channelName: 'HomeLAN Service',
        channelDescription: 'Поддержание связи с сервером',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 30000,
        isOnceEvent: false,
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Запуск foreground сервиса
  Future<void> start() async {
    if (!Platform.isAndroid || _isRunning) return;

    final permissionStatus = await FlutterForegroundTask.checkNotificationPermission();
    if (permissionStatus != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    await FlutterForegroundTask.requestIgnoreBatteryOptimization();

    await FlutterForegroundTask.startService(
      notificationTitle: 'HomeLAN',
      notificationText: 'Подключено к серверу',
      callback: _startCallback,
    );

    _isRunning = true;
    print('✅ Foreground service started');
  }

  /// Остановка сервиса
  Future<void> stop() async {
    if (!Platform.isAndroid || !_isRunning) return;

    await FlutterForegroundTask.stopService();
    _isRunning = false;
    print('🛑 Foreground service stopped');
  }

  /// Обновление уведомления
  Future<void> updateNotification({
    required String title,
    required String text,
  }) async {
    if (!Platform.isAndroid || !_isRunning) return;

    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }
}

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_ForegroundTaskHandler());
}

class _ForegroundTaskHandler extends TaskHandler {
  @override
  void onStart(DateTime timestamp, SendPort? sendPort) {
    print('🚀 Foreground task started');
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {
    // WebSocket ping происходит в websocket_service.dart
  }

  @override
  void onDestroy(DateTime timestamp, SendPort? sendPort) {
    print('💀 Foreground task destroyed');
  }
}