// lib/screens/waiting_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/auth_provider.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'settings_screen.dart';

class WaitingForPartnerScreen extends StatefulWidget {
  const WaitingForPartnerScreen({super.key});

  @override
  State<WaitingForPartnerScreen> createState() => _WaitingForPartnerScreenState();
}

class _WaitingForPartnerScreenState extends State<WaitingForPartnerScreen> with SingleTickerProviderStateMixin {
  Timer? _timer;
  bool _checking = false;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      await context.read<AuthProvider>().refreshPartner();
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.appName),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: s.settings,
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Center(
        child: FadeSlideIn(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ScaleTransition(
              scale: Tween(begin: 0.92, end: 1.0).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: const Icon(Icons.person_add_alt_1_outlined, size: 44, color: AppColors.accent),
              ),
            ),
            const SizedBox(height: 24),
            Text(s.waitingTitle, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(s.waitingHint, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
          ]),
        ),
      ),
    );
  }
}
