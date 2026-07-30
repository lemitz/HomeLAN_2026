import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class WaitingForPartnerScreen extends StatefulWidget {
  const WaitingForPartnerScreen({super.key});

  @override
  State<WaitingForPartnerScreen> createState() => _WaitingForPartnerScreenState();
}

class _WaitingForPartnerScreenState extends State<WaitingForPartnerScreen> {
  Timer? _checkTimer;

  @override
  void initState() {
    super.initState();
    // Проверяем каждые 5 секунд
    _checkTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkForPartner();
    });
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkForPartner() async {
    final auth = context.read<AuthProvider>();
    try {
      final partner = await auth.apiService.getPartner(auth.userId!);
      if (partner != null && mounted) {
        // Партнёр появился — перезагружаем
        await auth.init();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('HomeLAN'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.pushNamed(context, '/settings');
            },
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.hourglass_empty,
                size: 80,
                color: Colors.blue[400],
              ),
              const SizedBox(height: 24),
              const Text(
                'Ожидание собеседника',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Второй пользователь ещё не зарегистрирован.\n\nПопросите его установить приложение и создать аккаунт.',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[400],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Проверяем каждые 5 секунд...',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}