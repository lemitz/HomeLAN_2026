// lib/screens/lock_screen.dart
import 'package:flutter/material.dart';
import '../services/biometric_service.dart';

class LockScreen extends StatefulWidget {
  final Widget child;
  
  const LockScreen({super.key, required this.child});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with WidgetsBindingObserver {
  bool _isLocked = true;
  bool _isAuthenticating = false;
  bool _didInitialAuth = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Делаем первичную аутентификацию после первого кадра
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_didInitialAuth) {
        _didInitialAuth = true;
        _authenticate();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('🔒 Lifecycle: $state, isLocked: $_isLocked');
    
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // Приложение свернули — блокируем
      if (!_isLocked) {
        setState(() {
          _isLocked = true;
        });
        BiometricService().lock();
      }
    } else if (state == AppLifecycleState.resumed) {
      // Приложение развернули — если заблокировано, запрашиваем биометрию
      if (_isLocked && !_isAuthenticating) {
        _authenticate();
      }
    }
  }

  Future<void> _authenticate() async {
    if (_isAuthenticating) return;
    
    setState(() {
      _isAuthenticating = true;
    });

    try {
      final success = await BiometricService().authenticate();
      debugPrint('🔒 Auth result: $success');
      
      if (mounted) {
        setState(() {
          _isLocked = !success;
          _isAuthenticating = false;
        });
      }
    } catch (e) {
      debugPrint('🔒 Auth error: $e');
      if (mounted) {
        setState(() {
          // При ошибке — разблокируем чтобы не застрять
          _isLocked = false;
          _isAuthenticating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Если разблокировано — показываем child
    if (!_isLocked) {
      return widget.child;
    }
    
    // Экран блокировки
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.grey[900]!,
              Colors.black,
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.lock_outline,
                size: 80,
                color: Colors.blue[400],
              ),
              const SizedBox(height: 24),
              const Text(
                'HomeLAN',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '🔐 Защищено',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.green[400],
                ),
              ),
              const SizedBox(height: 48),
              if (_isAuthenticating)
                Column(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      'Проверка...',
                      style: TextStyle(color: Colors.grey[400]),
                    ),
                  ],
                )
              else
                ElevatedButton.icon(
                  onPressed: _authenticate,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Разблокировать'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}