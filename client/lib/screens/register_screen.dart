// lib/screens/register_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/providers.dart';
import '../widgets/ui.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final s = S.of(context);
    final username = _username.text.trim();
    final password = _password.text;
    final String? problem = username.isEmpty || password.isEmpty
        ? s.fillAllFields
        : username.length < 3
            ? s.usernameTooShort
            : password.length < 8
                ? s.passwordTooShort
                : password != _confirm.text
                    ? s.passwordsDontMatch
                    : null;
    if (problem != null) {
      showSnack(context, problem, error: true);
      return;
    }
    final auth = context.read<AuthProvider>();
    final ok = await auth.register(username, password);
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

    return Scaffold(
      appBar: AppBar(title: Text(s.signUp)),
      body: SafeArea(
        child: NarrowBody(
          child: FadeSlideIn(
            child: AutofillGroup(
              child: Column(children: [
                TextField(
                  controller: _username,
                  autofillHints: const [AutofillHints.newUsername],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(hintText: s.username, prefixIcon: const Icon(Icons.person_outline)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    hintText: s.password,
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirm,
                  obscureText: _obscure,
                  onSubmitted: (_) => _register(),
                  decoration: InputDecoration(hintText: s.repeatPassword, prefixIcon: const Icon(Icons.lock_outline)),
                ),
                const SizedBox(height: 20),
                PrimaryButton(label: s.createAccount, loading: busy, onPressed: _register),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
