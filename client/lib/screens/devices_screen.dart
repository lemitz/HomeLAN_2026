// lib/screens/devices_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/services.dart';
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
        _error = e is ApiException ? e.userMessage : 'Сервер недоступен';
        _loading = false;
      });
    }
  }

  Future<void> _revoke(Map<String, dynamic> device) async {
    final name = device['device_name'] as String? ?? 'Устройство';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отозвать устройство?'),
        content: Text('«$name» сразу потеряет доступ к аккаунту.\n\n'
            'Если устройство потеряно или украдено, учтите: на нём остался ключ шифрования, '
            'которым можно расшифровать перехваченную ранее переписку.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Отозвать'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await context.read<AuthProvider>().api.revokeDevice(device['device_id'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Устройство отозвано')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e is ApiException ? e.userMessage : 'Сервер недоступен')));
    }
  }

  IconData _icon(String type) {
    switch (type) {
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'windows':
        return Icons.desktop_windows;
      case 'macos':
        return Icons.desktop_mac;
      default:
        return Icons.computer;
    }
  }

  String _lastSeen(int ts) {
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts * 1000));
    if (diff.inMinutes < 5) return 'только что';
    if (diff.inHours < 1) return '${diff.inMinutes} мин назад';
    if (diff.inDays < 1) return '${diff.inHours} ч назад';
    return '${diff.inDays} дн назад';
  }

  @override
  Widget build(BuildContext context) {
    final full = _maxDevices > 0 && _devices.length >= _maxDevices;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Мои устройства'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!),
                    const SizedBox(height: 16),
                    ElevatedButton(onPressed: _load, child: const Text('Повторить')),
                  ]),
                )
              : ListView(
                  children: [
                    for (final d in _devices)
                      ListTile(
                        leading: Stack(children: [
                          Icon(_icon(d['device_type'] as String? ?? ''), size: 32),
                          if (d['is_online'] == true)
                            const Positioned(
                              right: 0,
                              bottom: 0,
                              child: CircleAvatar(radius: 5, backgroundColor: Colors.green),
                            ),
                        ]),
                        title: Text(d['device_name'] as String? ?? 'Устройство'),
                        subtitle: Text(d['is_current'] == true
                            ? 'Это устройство'
                            : d['is_online'] == true
                                ? 'в сети'
                                : 'был(а) ${_lastSeen(d['last_seen'] as int? ?? 0)}'),
                        trailing: d['is_current'] == true
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                onPressed: () => _revoke(d),
                              ),
                      ),
                    if (_maxDevices > 0)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('Устройств: ${_devices.length} из $_maxDevices',
                            style: TextStyle(color: Colors.grey[500])),
                      ),
                  ],
                ),
      floatingActionButton: _loading || _error != null
          ? null
          : FloatingActionButton.extended(
              onPressed: full
                  ? () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Достигнут лимит устройств. Отзовите старое устройство')))
                  : () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LinkDeviceScreen()))
                      .then((_) => _load()),
              icon: const Icon(Icons.add),
              label: const Text('Добавить устройство'),
            ),
    );
  }
}
