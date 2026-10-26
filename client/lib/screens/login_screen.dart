// lib/screens/login_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/providers.dart';
import '../theme.dart';
import '../widgets/server_address.dart';
import '../widgets/ui.dart';
import 'new_device_link_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final s = S.of(context);
    final username = _username.text.trim();
    if (username.isEmpty || _password.text.isEmpty) {
      showSnack(context, s.enterCredentials, error: true);
      return;
    }
    final auth = context.read<AuthProvider>();
    final ok = await auth.login(username, _password.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    } else if (auth.error != null) {
      showSnack(context, auth.error!, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final busy = context.select<AuthProvider, bool>((a) => a.isBusy);
    final notice = context.select<AuthProvider, String?>((a) => a.notice);

    return Scaffold(
      body: SafeArea(
        child: NarrowBody(
          child: AutofillGroup(
            child: Column(children: [
              const FadeSlideIn(child: AppLogo(size: 72)),
              const SizedBox(height: 20),
              FadeSlideIn(
                delay: const Duration(milliseconds: 40),
                child: Text(s.appName, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 32),
              AnimatedSize(
                duration: kMedium,
                curve: Curves.easeOutCubic,
                child: notice == null
                    ? const SizedBox(width: double.infinity)
                    : Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(notice, style: const TextStyle(color: AppColors.warning)),
                      ),
              ),
              FadeSlideIn(
                delay: const Duration(milliseconds: 80),
                child: Column(children: [
                  TextField(
                    controller: _username,
                    autofillHints: const [AutofillHints.username],
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(hintText: s.username, prefixIcon: const Icon(Icons.person_outline)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _login(),
                    decoration: InputDecoration(
                      hintText: s.password,
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  PrimaryButton(label: s.signIn, loading: busy, onPressed: _login),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())),
                    child: Text(s.createAccount),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              FadeSlideIn(
                delay: const Duration(milliseconds: 120),
                child: Column(children: [
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(s.or, style: const TextStyle(color: AppColors.muted)),
                    ),
                    const Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () =>
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const NewDeviceLinkScreen())),
                    icon: const Icon(Icons.qr_code_2),
                    label: Text(s.linkToAccount),
                  ),
                  const SizedBox(height: 24),
                  const ServerAddressField(),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
