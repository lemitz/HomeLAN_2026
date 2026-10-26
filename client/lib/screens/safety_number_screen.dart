// lib/screens/safety_number_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/auth_provider.dart';
import '../services/crypto_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

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
    final s = S.of(context);
    final auth = context.watch<AuthProvider>();
    final status = auth.partnerKeyStatus;
    final name = auth.partnerUsername ?? s.contact;
    final groups = _number?.split(' ') ?? [];

    return Scaffold(
      appBar: AppBar(title: Text(s.safetyNumber)),
      body: NarrowBody(
        child: Column(children: [
          if (status == PeerKeyStatus.mismatch)
            FadeSlideIn(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                child: Text(s.safetyMismatch(name), style: const TextStyle(color: AppColors.danger)),
              ),
            ),
          Text(s.safetyCompare(name), textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 20),
          Panel(
            child: AnimatedSwitcher(
              duration: kMedium,
              child: _number == null
                  ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
                  : GridView.count(
                      key: const ValueKey('n'),
                      crossAxisCount: 3,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      childAspectRatio: 2.4,
                      children: [
                        for (var i = 0; i < groups.length; i++)
                          FadeSlideIn(
                            delay: Duration(milliseconds: 25 * i),
                            child: Center(
                              child: Text(groups[i],
                                  style: const TextStyle(
                                      fontSize: 22,
                                      fontFamily: 'monospace',
                                      letterSpacing: 2,
                                      fontFeatures: [FontFeature.tabularFigures()])),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 24),
          AnimatedSwitcher(
            duration: kMedium,
            child: status == PeerKeyStatus.verified
                ? Row(key: const ValueKey('ok'), mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.verified, color: AppColors.success),
                    const SizedBox(width: 8),
                    Text(s.verified, style: const TextStyle(color: AppColors.success, fontSize: 16)),
                  ])
                : _number == null
                    ? const SizedBox.shrink()
                    : PrimaryButton(
                        key: const ValueKey('btn'),
                        icon: Icons.verified_user_outlined,
                        label: status == PeerKeyStatus.mismatch ? s.acceptNewKey : s.matches,
                        onPressed: () async {
                          await auth.markPartnerVerified();
                          if (context.mounted) Navigator.pop(context);
                        },
                      ),
          ),
        ]),
      ),
    );
  }
}
