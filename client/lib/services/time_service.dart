/// Сервис синхронизации времени с сервером
/// Решает проблему дрифта часов на устройствах
class TimeService {
  static final TimeService _instance = TimeService._internal();
  factory TimeService() => _instance;
  TimeService._internal();

  /// Разница между серверным и локальным временем (в секундах)
  /// serverTime = localTime + _timeDelta
  int _timeDelta = 0;

  /// Время последней синхронизации
  DateTime? _lastSync;

  /// Геттер для дельты
  int get timeDelta => _timeDelta;

  /// Синхронизировано ли время
  bool get isSynced => _lastSync != null;

  /// Синхронизация с сервером
  void syncFromServerResponse(int serverTime) {
    final localTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _timeDelta = serverTime - localTime;
    _lastSync = DateTime.now();
    
    if (_timeDelta.abs() > 5) {
      // Логируем если дрифт больше 5 секунд
      print('⏰ Time synced: delta = $_timeDelta seconds');
    }
  }

  /// Получить текущее "серверное" время (unix timestamp)
  int getNow() {
    final localTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return localTime + _timeDelta;
  }

  /// Получить текущее "серверное" время как DateTime
  DateTime getNowDateTime() {
    return DateTime.fromMillisecondsSinceEpoch(getNow() * 1000);
  }

  /// Проверить, не устарела ли синхронизация (больше 6 часов)
  bool needsResync() {
    if (_lastSync == null) return true;
    return DateTime.now().difference(_lastSync!).inHours >= 6;
  }

  /// Сбросить синхронизацию (при смене сервера и т.п.)
  void reset() {
    _timeDelta = 0;
    _lastSync = null;
  }
}