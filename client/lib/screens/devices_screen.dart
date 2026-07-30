import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import 'link_device_screen.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final authProvider = context.read<AuthProvider>();
      final devices = await authProvider.apiService.getDevices(authProvider.userId!);
      setState(() {
        _devices = devices;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _revokeDevice(String deviceId, String deviceName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Отозвать устройство?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Устройство "$deviceName" больше не сможет подключаться к аккаунту.',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Отозвать'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final authProvider = context.read<AuthProvider>();
      await authProvider.apiService.revokeDevice(
        userId: authProvider.userId!,
        deviceId: deviceId,
      );
      _loadDevices();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Устройство отозвано')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
    }
  }

  void _addDevice() {
    // Открываем экран добавления устройства (работает и на Windows, и на Android)
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const LinkDeviceScreen()),
    ).then((_) => _loadDevices());
  }

  IconData _getDeviceIcon(String deviceType) {
    switch (deviceType.toLowerCase()) {
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'windows':
        return Icons.desktop_windows;
      case 'macos':
        return Icons.desktop_mac;
      case 'linux':
        return Icons.computer;
      case 'web':
        return Icons.web;
      default:
        return Icons.devices;
    }
  }

  String _formatLastSeen(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 5) return 'Сейчас онлайн';
    if (diff.inHours < 1) return '${diff.inMinutes} мин назад';
    if (diff.inDays < 1) return '${diff.inHours} ч назад';
    if (diff.inDays < 7) return '${diff.inDays} дн назад';
    return '${date.day}.${date.month}.${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final currentDeviceId = authProvider.deviceId;

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[850],
        title: const Text('Мои устройства', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadDevices,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Ошибка: $_error', style: const TextStyle(color: Colors.white)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadDevices,
                        child: const Text('Повторить'),
                      ),
                    ],
                  ),
                )
              : _devices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.devices, size: 64, color: Colors.grey[600]),
                          const SizedBox(height: 16),
                          Text(
                            'Нет устройств',
                            style: TextStyle(color: Colors.grey[400], fontSize: 18),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Добавьте новое устройство',
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _devices.length,
                      itemBuilder: (context, index) {
                        final device = _devices[index];
                        final isCurrentDevice = device['device_id'] == currentDeviceId;
                        final isOnline = device['is_online'] == true;

                        return ListTile(
                          leading: Stack(
                            children: [
                              Icon(
                                _getDeviceIcon(device['device_type'] ?? ''),
                                size: 32,
                                color: Colors.white,
                              ),
                              if (isOnline)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: Colors.green,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.grey[900]!,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  device['device_name'] ?? 'Неизвестное устройство',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              if (isCurrentDevice)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Text(
                                    'Это устройство',
                                    style: TextStyle(fontSize: 12, color: Colors.blue),
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Text(
                            _formatLastSeen(device['last_seen'] ?? 0),
                            style: TextStyle(
                              color: isOnline ? Colors.green : Colors.grey,
                            ),
                          ),
                          trailing: isCurrentDevice
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                                  onPressed: () => _revokeDevice(
                                    device['device_id'],
                                    device['device_name'] ?? 'Устройство',
                                  ),
                                ),
                        );
                      },
                    ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addDevice,
        backgroundColor: Colors.blue[600],
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Добавить устройство', style: TextStyle(color: Colors.white)),
      ),
    );
  }
}