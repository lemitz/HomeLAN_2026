// lib/main.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/services.dart';
import 'services/mdns_service.dart';
import 'providers/providers.dart';
import 'screens/screens.dart';
import 'screens/chat_screen.dart';

const String defaultServerUrl = 'http://192.168.100.100:8080';

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => "DIRECT";
    client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    return client;
  }
}

late ApiService apiService;
late WebSocketService wsService;
late DatabaseService dbService;
late CryptoService cryptoService;
late NotificationService notificationService;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Определяем платформу один раз при старте
final bool isWindows = Platform.isWindows;
final bool isMobile = Platform.isAndroid || Platform.isIOS;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = MyHttpOverrides();

  String serverUrl = await _discoverOrLoadServerUrl();
  print('🏁 FINAL SERVER URL: $serverUrl');

  // Инициализируем ConnectionService для Windows
  if (isWindows) {
    ConnectionService().init(serverUrl);
  }

  apiService = ApiService(baseUrl: serverUrl);
  wsService = WebSocketService(baseUrl: serverUrl);
  dbService = DatabaseService();
  cryptoService = CryptoService();
  notificationService = NotificationService();
  
  if (isMobile) {
    await notificationService.init();
  }
  
  runApp(HomeLanApp(serverUrl: serverUrl));
}

Future<String> _discoverOrLoadServerUrl() async {
  final prefs = await SharedPreferences.getInstance();
  
  final savedUrl = prefs.getString('server_url');
  if (savedUrl != null) {
    print('📡 Found saved URL in cache: $savedUrl');
    if (await MDNSService.checkServer(savedUrl)) {
      print('✅ Saved URL is alive');
      return savedUrl;
    }
    print('⚠️ Saved URL not responding, searching again...');
  }
  
  print('📡 Searching for HomeLAN server via mDNS...');
  final discoveredUrl = await MDNSService.discoverServer();
  
  if (discoveredUrl != null) {
    await prefs.setString('server_url', discoveredUrl);
    print('🎉 mDNS found: $discoveredUrl');
    return discoveredUrl;
  }
  
  print('⚠️ mDNS failed, using default: $defaultServerUrl');
  return defaultServerUrl;
}

class HomeLanApp extends StatelessWidget {
  final String serverUrl;
  
  const HomeLanApp({super.key, required this.serverUrl});

  @override
  Widget build(BuildContext context) {
    // Определяем home виджет
    Widget homeWidget;
    if (isMobile) {
      homeWidget = const LockScreen(child: AppStartup());
    } else if (isWindows) {
      homeWidget = ServerGuardScreen(child: const AppStartup());
    } else {
      homeWidget = const AppStartup();
    }

    // Базовое приложение с провайдерами
    Widget app = MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AuthProvider(
            api: apiService,
            ws: wsService,
            db: dbService,
            crypto: cryptoService,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatProvider(
            ws: wsService,
            db: dbService,
            api: apiService,
            crypto: cryptoService,
            notifications: notificationService,
          ),
        ),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'HomeLAN',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        theme: ThemeData(
          brightness: Brightness.dark,
          primarySwatch: Colors.blue,
          scaffoldBackgroundColor: Colors.grey[900],
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          fontFamily: 'Roboto',
          visualDensity: VisualDensity.compact,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
              TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
              TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            },
          ),
        ),
        home: homeWidget,
      ),
    );

    // Для Windows оборачиваем в ConnectionService провайдер
    if (isWindows) {
      app = ChangeNotifierProvider.value(
        value: ConnectionService(),
        child: app,
      );
    }

    return app;
  }
}

class AppStartup extends StatefulWidget {
  const AppStartup({super.key});

  @override
  State<AppStartup> createState() => _AppStartupState();
}

class _AppStartupState extends State<AppStartup> with WidgetsBindingObserver {
  bool _isLoading = true;
  String? _error;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      final chat = context.read<ChatProvider>();
      chat.clearLocalData();
    }
  }

  Future<void> _init() async {
    if (_initialized) return;
    _initialized = true;
    
    try {
      final auth = context.read<AuthProvider>();
      await auth.init();
      
      if (auth.isLoggedIn && auth.userId != null) {
        final chat = context.read<ChatProvider>();
        chat.setUserId(auth.userId!);
        
        // Для Windows — запускаем мониторинг
        if (isWindows) {
          await ConnectionService().startMonitoring();
        }
      }
      
      notificationService.onNotificationTap = _onNotificationTap;
      
      if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _onNotificationTap(int? oderId) {}

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.grey[900],
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 80, color: Colors.blue[400]),
              const SizedBox(height: 24),
              const Text('HomeLAN', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              Text('🔐 E2E Encrypted', style: TextStyle(fontSize: 14, color: Colors.green[400])),
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.grey[900],
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 80, color: Colors.red[400]),
              const SizedBox(height: 24),
              const Text('Ошибка', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(_error!, style: TextStyle(color: Colors.grey[400]), textAlign: TextAlign.center),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() { _isLoading = true; _error = null; _initialized = false; });
                  _init();
                },
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }

    final auth = context.watch<AuthProvider>();
    
    if (auth.isLoggedIn) {
      if (auth.hasPartner) {
        return ChatScreen(
          userId: auth.partnerId!,
          username: auth.partnerUsername ?? 'Собеседник',
          isRootScreen: true,
        );
      } else {
        return const WaitingForPartnerScreen();
      }
    } else {
      return const LoginScreen();
    }
  }
}