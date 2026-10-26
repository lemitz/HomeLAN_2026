// lib/screens/safety_number_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/crypto_service.dart';

/// Сверка отпечатка ключей с собеседником (защита от подмены ключей в сети).
class SafetyNumberScreen extends StatefulWidget {
  const SafetyNumberScreen({super.key});

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  String? _number;

  @override
  void initState() {
    super.initState();
    context.read<AuthProvider>().safetyNumber().then((n) {
      if (mounted) setState(() => _number = n);
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final status = auth.partnerKeyStatus;
    final name = auth.partnerUsername ?? 'собеседником';
    final groups = _number?.split(' ') ?? [];

    return Scaffold(
      appBar: AppBar(title: const Text('Отпечаток ключей')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            if (status == PeerKeyStatus.mismatch)
              Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 24),
                decoration:
                    BoxDecoration(color: Colors.red.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                child: Text(
                  'Сервер прислал НОВЫЙ ключ для $name. Это бывает, если собеседник пересоздал аккаунт, '
                  'но может означать подмену. Отправка сообщений заблокирована, пока вы не сверите номер ниже '
                  'лично или по телефону.',
                  style: TextStyle(color: Colors.red[200]),
                ),
              ),
            Text('Сравните эти цифры с $name — у вас обоих они должны совпадать.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[400])),
            const SizedBox(height: 24),
            if (_number == null)
              const CircularProgressIndicator()
            else
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 16,
                runSpacing: 12,
                children: [
                  for (final g in groups)
                    Text(g, style: const TextStyle(fontSize: 24, fontFamily: 'monospace', letterSpacing: 2)),
                ],
              ),
            const SizedBox(height: 32),
            if (status == PeerKeyStatus.verified)
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.verified, color: Colors.green[400]),
                const SizedBox(width: 8),
                Text('Проверено', style: TextStyle(color: Colors.green[400])),
              ])
            else if (_number != null)
              ElevatedButton.icon(
                onPressed: () async {
                  await auth.markPartnerVerified();
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.verified_user),
                label: Text(status == PeerKeyStatus.mismatch ? 'Совпадает — принять новый ключ' : 'Совпадает'),
              ),
          ],
        ),
      ),
    );
  }
}
