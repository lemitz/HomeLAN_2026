// lib/main.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/strings.dart';
import 'providers/providers.dart';
import 'screens/screens.dart';
import 'services/services.dart';
import 'theme.dart';
import 'widgets/ui.dart';

class _LanHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // Сервер в локальной сети — системный прокси не нужен.
    return super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
  }
}

final bool isWindows = Platform.isWindows;
final bool isMobile = Platform.isAndroid || Platform.isIOS;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _LanHttpOverrides();

  final locale = LocaleController();
  await locale.load();

  // Расшифрованные файлы с прошлого запуска не храним.
  await ChatProvider.clearDecryptedFiles().catchError((_) {});

  final serverUrl = await ServerConfig.resolve();
  ConnectionService().init(serverUrl);

  final api = ApiService(baseUrl: serverUrl);
  final ws = WebSocketService(baseUrl: serverUrl);
  final db = DatabaseService();
  final crypto = CryptoService();
  final notifications = NotificationService();
  if (isMobile) {
    await notifications.init();
    await ForegroundService().init();
  }

  runApp(HomeLanApp(api: api, ws: ws, db: db, crypto: crypto, notifications: notifications, locale: locale));
}

class HomeLanApp extends StatelessWidget {
  final ApiService api;
  final WebSocketService ws;
  final DatabaseService db;
  final CryptoService crypto;
  final NotificationService notifications;
  final LocaleController locale;

  const HomeLanApp({
    super.key,
    required this.api,
    required this.ws,
    required this.db,
    required this.crypto,
    required this.notifications,
    required this.locale,
  });

  static final _theme = buildTheme();

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: api),
        Provider.value(value: db),
        Provider.value(value: crypto),
        ChangeNotifierProvider.value(value: locale),
        ChangeNotifierProvider.value(value: ws),
        ChangeNotifierProvider.value(value: ConnectionService()),
        ChangeNotifierProvider(
          create: (_) => AuthProvider(api: api, ws: ws, db: db, crypto: crypto)..init(),
        ),
        ChangeNotifierProxyProvider<AuthProvider, ChatProvider>(
          create: (_) => ChatProvider(ws: ws, db: db, api: api, crypto: crypto, notifications: notifications),
          update: (_, auth, chat) => chat!..attachAuth(auth),
        ),
      ],
      child: Consumer<LocaleController>(
        builder: (context, lc, _) => MaterialApp(
          onGenerateTitle: (ctx) => S.of(ctx).appName,
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          theme: _theme,
          darkTheme: _theme,
          locale: lc.locale,
          supportedLocales: S.supportedLocales,
          localizationsDelegates: const [
            S.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          // Язык системы: русский, если он есть в списке языков, иначе английский.
          localeListResolutionCallback: (locales, _) => S.resolve(locales),
          // Блокировка и защита сервера — поверх навигатора: закрывают все
          // экраны, но не уничтожают их состояние.
          builder: (context, child) {
            Widget app = child ?? const SizedBox.shrink();
            if (isWindows) app = ServerGuard(child: app);
            if (isMobile) app = LockGate(child: app);
            return AppLifecycleHooks(child: app);
          },
          home: const RootScreen(),
        ),
      ),
    );
  }
}

/// Выбирает экран по состоянию авторизации (с плавной сменой).
class RootScreen extends StatelessWidget {
  const RootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.select<AuthProvider, AuthStatus>((a) => a.status);
    final hasPartner = context.select<AuthProvider, bool>((a) => a.hasPartner);
    final Widget screen = switch (status) {
      AuthStatus.loading => const SplashScreen(key: ValueKey('splash')),
      AuthStatus.loggedOut => const LoginScreen(key: ValueKey('login')),
      AuthStatus.loggedIn =>
        hasPartner ? const ChatScreen(key: ValueKey('chat')) : const WaitingForPartnerScreen(key: ValueKey('waiting')),
    };
    return AnimatedSwitcher(
      duration: kMedium,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(anim), child: child),
      ),
      child: screen,
    );
  }
}

/// При возвращении в приложение — сразу переподключаемся и проверяем сессию.
class AppLifecycleHooks extends StatefulWidget {
  final Widget child;
  const AppLifecycleHooks({super.key, required this.child});

  @override
  State<AppLifecycleHooks> createState() => _AppLifecycleHooksState();
}

class _AppLifecycleHooksState extends State<AppLifecycleHooks> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<WebSocketService>().reconnectNow();
      context.read<AuthProvider>().refreshSession();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: AppLogo(size: 72)));
  }
}
