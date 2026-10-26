// lib/l10n/strings.dart
//
// Строки интерфейса (русский / английский). По умолчанию — язык системы:
// русский для ru, для всех остальных — английский.
//
// В виджетах: S.of(context).xxx. В сервисах без контекста: S.current.xxx.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class S {
  S(this.locale) : ru = locale.languageCode == 'ru';

  final Locale locale;
  final bool ru;

  static S current = S(resolve(PlatformDispatcher.instance.locales));

  static const supportedLocales = [Locale('en'), Locale('ru')];
  static const LocalizationsDelegate<S> delegate = _SDelegate();

  static S of(BuildContext context) => Localizations.of<S>(context, S) ?? current;

  /// Первый поддерживаемый язык из списка системных, иначе английский.
  static Locale resolve(List<Locale>? locales) {
    for (final l in locales ?? const <Locale>[]) {
      if (l.languageCode == 'ru') return const Locale('ru');
      if (l.languageCode == 'en') return const Locale('en');
    }
    return const Locale('en');
  }

  String _(String ru, String en) => this.ru ? ru : en;

  // ============ ОБЩЕЕ ============
  String get appName => 'HomeLAN';
  String get cancel => _('Отмена', 'Cancel');
  String get close => _('Закрыть', 'Close');
  String get save => _('Сохранить', 'Save');
  String get retry => _('Повторить', 'Retry');
  String get copy => _('Копировать', 'Copy');
  String get copied => _('Скопировано', 'Copied');
  String get delete => _('Удалить', 'Delete');
  String get done => _('Готово', 'Done');
  String get next => _('Продолжить', 'Continue');
  String get open => _('Открыть', 'Open');
  String get server => _('Сервер', 'Server');
  String get serverUnavailable => _('Сервер недоступен', 'Server unavailable');
  String get serverNotResponding => _('Сервер не отвечает', 'Server is not responding');
  String get connecting => _('Подключение…', 'Connecting…');
  String get reconnect => _('Переподключиться', 'Reconnect');
  String get invalidAddress => _('Неверный адрес', 'Invalid address');
  String error(Object e) => _('Ошибка: $e', 'Error: $e');

  // ============ ВХОД ============
  String get username => _('Логин', 'Username');
  String get password => _('Пароль', 'Password');
  String get repeatPassword => _('Повторите пароль', 'Repeat password');
  String get signIn => _('Войти', 'Sign in');
  String get signUp => _('Регистрация', 'Sign up');
  String get createAccount => _('Создать аккаунт', 'Create account');
  String get linkToAccount => _('Привязать к аккаунту', 'Link to account');
  String get or => _('или', 'or');
  String get enterCredentials => _('Введите логин и пароль', 'Enter username and password');
  String get fillAllFields => _('Заполните все поля', 'Fill in all fields');
  String get usernameTooShort => _('Логин — минимум 3 символа', 'Username must be at least 3 characters');
  String get passwordTooShort => _('Пароль — минимум 8 символов', 'Password must be at least 8 characters');
  String get passwordsDontMatch => _('Пароли не совпадают', "Passwords don't match");
  String get sessionInvalid => _('Сессия недействительна. Войдите снова', 'Session expired. Sign in again');
  String get noIdentityOnDevice =>
      _('На устройстве нет ключа. Привяжите его к аккаунту', 'No key on this device. Link it to your account');
  String get badServerResponse => _('Некорректный ответ сервера', 'Invalid server response');
  String get linkKeyMismatch =>
      _('Полученный ключ не совпадает с ключом аккаунта', "The received key doesn't match the account key");
  String get accountKeyMismatch => _('Ключ устройства не совпадает с ключом аккаунта. Возможна подмена сервера',
      "This device's key doesn't match the account key. The server may be spoofed");
  String get noToken => _('Сервер не выдал токен', 'The server returned no token');
  String get networkError => _('Сервер недоступен. Проверьте сеть', 'Server unreachable. Check your network');

  String serverError(int status) => _('Ошибка сервера ($status)', 'Server error ($status)');

  String? apiError(String code) => switch (code) {
        'invalid_credentials' => _('Неверный логин или пароль', 'Wrong username or password'),
        'rate_limited' => _('Слишком много попыток, подождите', 'Too many attempts, try again later'),
        'device_not_linked' => _('Устройство не привязано к аккаунту', "This device isn't linked to the account"),
        'device_revoked' => _('Устройство отозвано', 'This device was revoked'),
        'user_limit' => _('Достигнут лимит пользователей', 'User limit reached'),
        'username_taken' => _('Логин занят', 'Username is taken'),
        'weak_password' => passwordTooShort,
        'invalid_username' => _('Логин: 3–32 символа — буквы, цифры, _ . -', 'Username: 3–32 letters, digits, _ . -'),
        'device_limit' => _('Лимит устройств. Отзовите старое', 'Device limit reached. Revoke an old one'),
        'invalid_link_code' => _('Код привязки неверный или устарел', 'Link code is invalid or expired'),
        'file_too_large' => _('Файл слишком большой', 'File is too large'),
        'quota_exceeded' => _('Хранилище сервера заполнено', 'Server storage is full'),
        'disk_full' => _('На сервере нет места', 'Server is out of disk space'),
        'unauthorized' => sessionInvalid,
        _ => null,
      };

  // ============ КРИПТО ============
  String get badKeyLength => _('Неверная длина ключа', 'Invalid key length');
  String get noLocalKey => _('Нет ключа шифрования', 'No encryption key');
  String get peerKeyChanged =>
      _('Ключ собеседника изменился — сверьте отпечаток', "Contact's key changed — verify the safety number");
  String get noPeerKey => _('Нет ключа собеседника', 'No contact key');
  String get unsupportedFormat => _('Неподдерживаемый формат', 'Unsupported format');
  String get foreignMessage => _('Чужое сообщение', 'Message from another chat');
  String get tampered => _('Сообщение повреждено', 'Message is corrupted');
  String get linkDataCorrupt => _('Данные привязки повреждены', 'Link data is corrupted');
  String get linkWrongDevice => _('Код для другого устройства', 'This code is for another device');
  String get cantDecrypt => _('Не удалось расшифровать', "Can't decrypt");
  String get noPartnerYet => _('Собеседник ещё не подключён', "Contact hasn't joined yet");
  String get noFileData => _('Нет данных файла', 'No file data');

  // ============ ЧАТ ============
  String get contact => _('Собеседник', 'Contact');
  String get messageHint => _('Сообщение', 'Message');
  String get sendingBlocked => _('Отправка заблокирована', 'Sending is blocked');
  String get typing => _('печатает…', 'typing…');
  String get offline => _('нет связи', 'offline');
  String get syncing => _('синхронизация…', 'syncing…');
  String get keyChangedShort => _('ключ изменился', 'key changed');
  String get noKeyShort => _('нет ключа', 'no key');
  String get keyChangedBanner => _('Ключ собеседника изменился', "Contact's key changed");
  String get verify => _('Проверить', 'Verify');
  String get noMessages => _('Сообщений пока нет', 'No messages yet');
  String get today => _('Сегодня', 'Today');
  String get yesterday => _('Вчера', 'Yesterday');
  String get search => _('Поиск', 'Search');
  String get nothingFound => _('Ничего не найдено', 'No results');
  String get gallery => _('Галерея', 'Gallery');
  String get camera => _('Камера', 'Camera');
  String get file => _('Файл', 'File');
  String get resend => _('Отправить снова', 'Resend');
  String get deleteForAll => _('Удалить у всех', 'Delete for everyone');
  String get editContact => _('Изменить контакт', 'Edit contact');
  String get name => _('Имя', 'Name');
  String get safetyNumber => _('Отпечаток ключей', 'Safety number');
  String get devices => _('Устройства', 'Devices');
  String get settings => _('Настройки', 'Settings');
  String get encrypting => _('Шифрование', 'Encrypting');
  String get uploading => _('Отправка', 'Uploading');
  String get pickFailed => _('Не удалось выбрать файл', "Couldn't pick the file");
  String notSent(Object e) => _('Не отправлено: $e', 'Not sent: $e');
  String get notSentShort => _('Не отправлено', 'Not sent');
  String get downloadFailed => _('Не удалось загрузить файл', "Couldn't download the file");
  String get openExecTitle => _('Открыть исполняемый файл?', 'Open an executable file?');
  String openExecBody(String name) => _('«$name» может запустить программу.', '"$name" can run a program.');
  String get noAppToOpen => _('Нет приложения для этого файла', 'No app can open this file');
  String get newMessage => _('Новое сообщение', 'New message');
  String get photo => _('📷 Фото', '📷 Photo');
  String get fileNotification => _('📎 Файл', '📎 File');
  String get notifChannel => _('Сообщения', 'Messages');
  String get notifChannelDesc => _('Новые сообщения', 'New messages');
  String get fgChannelDesc => _('Связь с сервером', 'Server connection');
  String get fgText => _('На связи', 'Connected');

  String dateLabel(DateTime d) {
    const ruMonths = [
      'января', 'февраля', 'марта', 'апреля', 'мая', 'июня', //
      'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
    ];
    const enMonths = [
      'January', 'February', 'March', 'April', 'May', 'June', //
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final now = DateTime.now();
    bool same(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
    if (same(d, now)) return today;
    if (same(d, now.subtract(const Duration(days: 1)))) return yesterday;
    final year = d.year == now.year ? '' : ' ${d.year}';
    return ru
        ? '${d.day} ${ruMonths[d.month - 1]}$year'
        : '${enMonths[d.month - 1]} ${d.day}${year.isEmpty ? '' : ','}$year';
  }

  // ============ БЛОКИРОВКА ============
  String get unlockReason => _('Разблокируйте HomeLAN', 'Unlock HomeLAN');
  String get unlock => _('Разблокировать', 'Unlock');
  String get unlockFailed => _('Не удалось подтвердить', 'Authentication failed');

  // ============ ОЖИДАНИЕ ============
  String get waitingTitle => _('Ждём собеседника', 'Waiting for contact');
  String get waitingHint => _('Второй пользователь ещё не зарегистрировался', "The second user hasn't signed up yet");

  // ============ УСТРОЙСТВА ============
  String get thisDevice => _('Это устройство', 'This device');
  String get online => _('в сети', 'online');
  String get revokeTitle => _('Отозвать устройство?', 'Revoke device?');
  String revokeBody(String name) => _('«$name» потеряет доступ. Ключ шифрования на нём останется.',
      '"$name" will lose access. Its encryption key stays on it.');
  String get revoke => _('Отозвать', 'Revoke');
  String get revoked => _('Устройство отозвано', 'Device revoked');
  String get addDevice => _('Добавить устройство', 'Add device');
  String get deviceLimitReached => apiError('device_limit')!;
  String lastSeen(int unixSeconds) {
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000));
    if (diff.inMinutes < 5) return _('только что', 'just now');
    if (diff.inHours < 1) return _('${diff.inMinutes} мин назад', '${diff.inMinutes} min ago');
    if (diff.inDays < 1) return _('${diff.inHours} ч назад', '${diff.inHours} h ago');
    return _('${diff.inDays} дн назад', '${diff.inDays} d ago');
  }

  // ============ ПРИВЯЗКА ============
  String get linkTitle => _('Привязка устройства', 'Link device');
  String get linkStep1 => _('На основном устройстве: Устройства → Добавить', 'On your main device: Devices → Add');
  String get copyAsText => _('Скопировать текст', 'Copy as text');
  String get verificationCode => _('Код сверки', 'Verification code');
  String get linkStep2 => _('Ответ основного устройства', "Main device's response");
  String get scan => _('Сканировать', 'Scan');
  String get pasteResponse => _('Или вставьте текст (HL2:…)', 'Or paste text (HL2:…)');
  String get pasteRequest => _('Или вставьте текст (HL1:…)', 'Or paste text (HL1:…)');
  String get link => _('Привязать', 'Link');
  String get notLinkResponse => _('Это не ответ привязки (HL2:…)', 'Not a link response (HL2:…)');
  String get notLinkRequest => _('Это не запрос привязки (HL1:…)', 'Not a link request (HL1:…)');
  String get linking => _('Привязка…', 'Linking…');
  String get addDeviceHint => _('На новом устройстве: «Привязать к аккаунту»', 'On the new device: "Link to account"');
  String get confirmDevice => _('Подтвердите устройство', 'Confirm device');
  String get codesMustMatch => _('Коды на обоих экранах должны совпадать', 'Codes on both screens must match');
  String get codesDiffer => _('Не совпадают', "Don't match");
  String get codesMatch => _('Совпадают', 'They match');
  String get showToNewDevice => _('Покажите новому устройству', 'Show this to the new device');
  String validFor(String mmss) => _('Действует $mmss', 'Valid for $mmss');
  String get scanFromNewDevice => _('QR-код с нового устройства', 'QR code from the new device');
  String get scanFromMainDevice => _('QR-код с основного устройства', 'QR code from the main device');
  String get wrongQr => _('Не тот QR-код', 'Wrong QR code');

  // ============ ОТПЕЧАТОК ============
  String safetyCompare(String name) => _('Сравните цифры с $name', 'Compare these digits with $name');
  String safetyMismatch(String name) => _('Сервер прислал новый ключ $name. Отправка заблокирована до сверки.',
      'The server sent a new key for $name. Sending is blocked until verified.');
  String get verified => _('Проверено', 'Verified');
  String get matches => _('Совпадает', 'Matches');
  String get acceptNewKey => _('Совпадает — принять ключ', 'Matches — accept key');

  // ============ НАСТРОЙКИ ============
  String get account => _('Аккаунт', 'Account');
  String get admin => _('Админ', 'Admin');
  String get notifications => _('Уведомления', 'Notifications');
  String get language => _('Язык', 'Language');
  String get languageSystem => _('Системный', 'System');
  String get appearance => _('Оформление', 'Appearance');
  String get myMessages => _('Мои сообщения', 'My messages');
  String get incomingMessages => _('Входящие', 'Incoming');
  String get security => _('Безопасность', 'Security');
  String get signOut => _('Выйти', 'Sign out');
  String get signOutBody => _('Кеш сообщений будет очищен, ключ останется на устройстве.',
      'The message cache will be cleared; the key stays on this device.');
  String get fullWipe => _('Полная очистка', 'Full wipe');
  String get fullWipeBody => _(
      'Ключ и привязка устройства будут удалены безвозвратно. Если это единственное устройство — история станет нечитаемой.',
      'The key and device link will be deleted permanently. If this is your only device, the history becomes unreadable.');
  String get wipe => _('Удалить всё', 'Wipe');
  String get about => _('О приложении', 'About');
  String version(String v) => _('Версия $v', 'Version $v');
  String get deviceId => _('ID устройства', 'Device ID');
  String get e2eHey => _('Эй!', 'Hey!');
  String get e2eOk => _('Ладно, понял', 'Okay, got it');
  List<String> get e2eJokes => ru
      ? const [
          'Ты чё, дурак? 🤡',
          'Хорошая попытка, но нет 😏',
          'Шифрование — это не опция, это образ жизни 🔐',
          'Даже не думай об этом 🙅',
          'Нет. Просто нет. ❌',
          'Это кнопка-ловушка 🪤',
          'Может тебе ещё пароль 1234 поставить? 🤔',
        ]
      : const [
          'Are you serious? 🤡',
          'Nice try, but no 😏',
          "Encryption isn't an option, it's a lifestyle 🔐",
          "Don't even think about it 🙅",
          'No. Just no. ❌',
          "It's a trap button 🪤",
          'Want password 1234 too? 🤔',
        ];
}

class _SDelegate extends LocalizationsDelegate<S> {
  const _SDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<S> load(Locale locale) {
    final s = S(S.resolve([locale]));
    S.current = s;
    return SynchronousFuture(s);
  }

  @override
  bool shouldReload(_SDelegate old) => false;
}

/// Выбор языка: системный (по умолчанию), английский или русский.
class LocaleController extends ChangeNotifier {
  static const _key = 'app_locale';
  String _mode = 'system';

  String get mode => _mode;
  Locale? get locale => _mode == 'system' ? null : Locale(_mode);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = prefs.getString(_key) ?? 'system';
    if (locale != null) S.current = S(locale!);
  }

  Future<void> setMode(String mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode);
  }
}
