// lib/screens/devices_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/auth_provider.dart';
import '../services/services.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'link_device_screen.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  int _maxDevices = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await context.read<AuthProvider>().api.devices();
      if (!mounted) return;
      setState(() {
        _devices = (data['devices'] as List).cast<Map<String, dynamic>>();
        _maxDevices = data['max_devices'] as int? ?? 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.userMessage : S.of(context).serverUnavailable;
        _loading = false;
      });
    }
  }

  Future<void> _revoke(Map<String, dynamic> device) async {
    final s = S.of(context);
    final name = device['device_name'] as String? ?? '';
    if (!await confirmDialog(context, title: s.revokeTitle, body: s.revokeBody(name), action: s.revoke, danger: true)) {
      return;
    }
    if (!mounted) return;
    try {
      await context.read<AuthProvider>().api.revokeDevice(device['device_id'] as String);
      if (!mounted) return;
      showSnack(context, s.revoked);
      _load();
    } catch (e) {
      if (mounted) showSnack(context, e is ApiException ? e.userMessage : s.serverUnavailable, error: true);
    }
  }

  static IconData _icon(String type) => switch (type) {
        'android' => Icons.phone_android,
        'ios' => Icons.phone_iphone,
        'windows' => Icons.desktop_windows_outlined,
        'macos' => Icons.desktop_mac_outlined,
        _ => Icons.computer,
      };

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final full = _maxDevices > 0 && _devices.length >= _maxDevices;

    final Widget body;
    if (_loading) {
      body = const Center(key: ValueKey('loading'), child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        key: const ValueKey('error'),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!, style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 16),
          OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(160, 48)),
              onPressed: _load,
              child: Text(s.retry)),
        ]),
      );
    } else {
      body = ListView(key: const ValueKey('list'), padding: const EdgeInsets.only(top: 8, bottom: 96), children: [
        Group(
          title: _maxDevices > 0 ? '${_devices.length} / $_maxDevices' : null,
          children: [
            for (var i = 0; i < _devices.length; i++)
              FadeSlideIn(delay: Duration(milliseconds: 30 * i), child: _tile(s, _devices[i])),
          ],
        ),
      ]);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(s.devices),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load)],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: AnimatedSwitcher(duration: kMedium, child: body),
      ),
      floatingActionButton: AnimatedScale(
        scale: _loading || _error != null ? 0 : 1,
        duration: kMedium,
        curve: Curves.easeOutBack,
        child: FloatingActionButton.extended(
          onPressed: full
              ? () => showSnack(context, s.deviceLimitReached, error: true)
              : () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LinkDeviceScreen()))
                  .then((_) => _load()),
          icon: const Icon(Icons.add),
          label: Text(s.addDevice),
        ),
      ),
    );
  }

  Widget _tile(S s, Map<String, dynamic> d) {
    final current = d['is_current'] == true;
    final online = d['is_online'] == true;
    return ListTile(
      leading: Stack(clipBehavior: Clip.none, children: [
        Icon(_icon(d['device_type'] as String? ?? ''), size: 28),
        if (online)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: AppColors.success,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.surface, width: 2),
              ),
            ),
          ),
      ]),
      title: Text(d['device_name'] as String? ?? ''),
      subtitle: Text(
        current ? s.thisDevice : (online ? s.online : s.lastSeen(d['last_seen'] as int? ?? 0)),
        style: TextStyle(color: current ? AppColors.accent : AppColors.muted),
      ),
      trailing: current
          ? null
          : IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: AppColors.danger),
              tooltip: s.revoke,
              onPressed: () => _revoke(d),
            ),
    );
  }
}
