// lib/main.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/providers.dart';
import 'screens/screens.dart';
import 'services/services.dart';

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

  runApp(HomeLanApp(api: api, ws: ws, db: db, crypto: crypto, notifications: notifications));
}

class HomeLanApp extends StatelessWidget {
  final ApiService api;
  final WebSocketService ws;
  final DatabaseService db;
  final CryptoService crypto;
  final NotificationService notifications;

  const HomeLanApp({
    super.key,
    required this.api,
    required this.ws,
    required this.db,
    required this.crypto,
    required this.notifications,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: api),
        Provider.value(value: db),
        Provider.value(value: crypto),
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
      child: MaterialApp(
        title: 'HomeLAN',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.blue,
          scaffoldBackgroundColor: Colors.grey[900],
          splashFactory: NoSplash.splashFactory,
          visualDensity: VisualDensity.compact,
        ),
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
    );
  }
}

/// Выбирает экран по состоянию авторизации.
class RootScreen extends StatelessWidget {
  const RootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    switch (auth.status) {
      case AuthStatus.loading:
        return const SplashScreen();
      case AuthStatus.loggedOut:
        return const LoginScreen();
      case AuthStatus.loggedIn:
        return auth.hasPartner ? const ChatScreen() : const WaitingForPartnerScreen();
    }
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
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 80, color: Colors.blue[400]),
            const SizedBox(height: 24),
            const Text('HomeLAN', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
