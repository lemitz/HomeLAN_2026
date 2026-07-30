// lib/screens/server_guard_screen.dart

import 'package:flutter/material.dart';
import '../services/connection_service.dart';

class ServerGuardScreen extends StatefulWidget {
  final Widget child;
  
  const ServerGuardScreen({super.key, required this.child});

  @override
  State<ServerGuardScreen> createState() => _ServerGuardScreenState();
}

class _ServerGuardScreenState extends State<ServerGuardScreen> {
  final _conn = ConnectionService();
  bool _isRetrying = false;

  @override
  void initState() {
    super.initState();
    _conn.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _conn.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _retry() async {
    if (_isRetrying) return;
    setState(() => _isRetrying = true);
    await _conn.tryReconnect();
    if (mounted) setState(() => _isRetrying = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_conn.isConnected) {
      return widget.child;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.grey[900]!, Colors.black],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _conn.isDisconnected ? Icons.cloud_off : Icons.cloud_sync,
                size: 80,
                color: _conn.isDisconnected ? Colors.red[400] : Colors.blue[400],
              ),
              const SizedBox(height: 24),
              const Text(
                'HomeLAN',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 16),
              Text(
                _conn.isDisconnected ? '⚠️ Сервер недоступен' : 'Подключение...',
                style: TextStyle(
                  fontSize: 16,
                  color: _conn.isDisconnected ? Colors.red[400] : Colors.blue[400],
                ),
              ),
              if (_conn.disconnectReason != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _conn.disconnectReason!,
                    style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                  ),
                ),
              const SizedBox(height: 48),
              if (_conn.state == ServerConnectionState.checking || _isRetrying)
                const CircularProgressIndicator()
              else if (_conn.isDisconnected)
                ElevatedButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Переподключиться'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}