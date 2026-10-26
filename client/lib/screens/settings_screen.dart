// lib/screens/settings_screen.dart
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/providers.dart';
import '../theme.dart';
import '../version.dart';
import '../widgets/ui.dart';
import 'devices_screen.dart';
import 'safety_number_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final locale = context.watch<LocaleController>();

    Widget nav(IconData icon, String title, Widget screen) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          trailing: const Icon(Icons.chevron_right, color: AppColors.muted),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => screen)),
        );

    return Scaffold(
      appBar: AppBar(title: Text(s.settings)),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          FadeSlideIn(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Row(children: [
                Avatar(name: auth.username ?? '?', color: AppColors.accent, size: 56),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(auth.username ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                    if (auth.isAdmin)
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(s.admin,
                            style:
                                const TextStyle(color: AppColors.warning, fontSize: 11, fontWeight: FontWeight.w600)),
                      ),
                  ]),
                ),
              ]),
            ),
          ),
          Group(title: s.security, children: [
            nav(Icons.devices_outlined, s.devices, const DevicesScreen()),
            if (auth.hasPartner) nav(Icons.fingerprint, s.safetyNumber, const SafetyNumberScreen()),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('E2E'),
              trailing: Switch(value: true, onChanged: (v) => v ? null : _e2eJoke(context)),
            ),
          ]),
          Group(title: s.appearance, children: [
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(s.language),
              trailing: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: locale.mode,
                  borderRadius: BorderRadius.circular(14),
                  dropdownColor: AppColors.surfaceHigh,
                  items: [
                    DropdownMenuItem(value: 'system', child: Text(s.languageSystem)),
                    const DropdownMenuItem(value: 'en', child: Text('English')),
                    const DropdownMenuItem(value: 'ru', child: Text('Русский')),
                  ],
                  onChanged: (v) => v == null ? null : locale.setMode(v),
                ),
              ),
            ),
            _colorTile(context, s.myMessages, chat.myBubbleColor, chat.setMyBubbleColor),
            _colorTile(context, s.incomingMessages, chat.otherBubbleColor, chat.setOtherBubbleColor),
            SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: Text(s.notifications),
              value: chat.notificationsEnabled,
              onChanged: chat.setNotificationsEnabled,
            ),
          ]),
          Group(children: [
            ListTile(
              leading: const Icon(Icons.logout, color: AppColors.warning),
              title: Text(s.signOut, style: const TextStyle(color: AppColors.warning)),
              onTap: () => _logout(context, auth),
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever_outlined, color: AppColors.danger),
              title: Text(s.fullWipe, style: const TextStyle(color: AppColors.danger)),
              onTap: () => _wipe(context, auth),
            ),
          ]),
          Group(children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(s.about),
              subtitle: Text(s.version(appVersion), style: const TextStyle(color: AppColors.muted)),
              onTap: () => _about(context),
            ),
            ListTile(
              leading: const Icon(Icons.smartphone_outlined),
              title: Text(s.deviceId),
              subtitle: Text(auth.deviceId ?? '-', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
              onTap: () {
                if (auth.deviceId == null) return;
                Clipboard.setData(ClipboardData(text: auth.deviceId!));
                showSnack(context, s.copied);
              },
            ),
          ]),
        ],
      ),
    );
  }

  Widget _colorTile(BuildContext context, String title, int color, Future<void> Function(int) onPick) {
    return ListTile(
      leading: const Icon(Icons.palette_outlined),
      title: Text(title),
      trailing: AnimatedContainer(
        duration: kMedium,
        width: 28,
        height: 28,
        decoration:
            BoxDecoration(color: Color(color), shape: BoxShape.circle, border: Border.all(color: Colors.white24)),
      ),
      onTap: () => showModalBottomSheet(
        context: context,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Wrap(spacing: 14, runSpacing: 14, children: [
              for (final c in AppColors.bubblePalette)
                GestureDetector(
                  onTap: () {
                    onPick(c.toARGB32());
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: color == c.toARGB32() ? Border.all(color: Colors.white, width: 3) : null,
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  void _e2eJoke(BuildContext context) {
    final s = S.of(context);
    final jokes = s.e2eJokes;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.e2eHey),
        content: Text(jokes[Random().nextInt(jokes.length)], style: const TextStyle(fontSize: 16)),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(s.e2eOk))],
      ),
    );
  }

  void _about(BuildContext context) {
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const AppLogo(size: 56),
        title: Text(s.appName),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(s.version('$appVersion · v$protocolVersion'), style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 12),
          const Text('X25519 · HKDF · XChaCha20-Poly1305', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          const Text('© 2026 HomeLAN', style: TextStyle(color: AppColors.muted, fontSize: 12)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.close))],
      ),
    );
  }

  Future<void> _logout(BuildContext context, AuthProvider auth) async {
    final s = S.of(context);
    if (!await confirmDialog(context, title: s.signOut, body: s.signOutBody, action: s.signOut)) return;
    if (!context.mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await auth.logout();
  }

  Future<void> _wipe(BuildContext context, AuthProvider auth) async {
    final s = S.of(context);
    if (!await confirmDialog(context, title: s.fullWipe, body: s.fullWipeBody, action: s.wipe, danger: true)) {
      return;
    }
    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    await auth.fullWipe();
    navigator.popUntil((r) => r.isFirst);
  }
}
