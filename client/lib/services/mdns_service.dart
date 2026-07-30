// lib/services/mdns_service.dart
import 'dart:async';
import 'dart:io';
import 'package:multicast_dns/multicast_dns.dart';

class MDNSService {
  static const String serviceType = '_homelan._tcp.local';
  
  /// Ищет HomeLAN сервер в локальной сети
  /// Возвращает URL вида "http://192.168.1.100:8080" или null
  static Future<String?> discoverServer({Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final MDnsClient client = MDnsClient();
      await client.start();

      String? serverUrl;
      
      // Ищем PTR записи
      await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(serviceType),
      ).timeout(timeout, onTimeout: (sink) => sink.close())) {
        
        // Получаем SRV запись
        await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
        ).timeout(const Duration(seconds: 2), onTimeout: (sink) => sink.close())) {
          
          // Получаем IP адрес
          await for (final IPAddressResourceRecord ip in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
          ).timeout(const Duration(seconds: 2), onTimeout: (sink) => sink.close())) {
            
            serverUrl = 'http://${ip.address.address}:${srv.port}';
            print('📡 mDNS: Found server at $serverUrl');
            break;
          }
          if (serverUrl != null) break;
        }
        if (serverUrl != null) break;
      }

      client.stop();
      return serverUrl;
    } catch (e) {
      print('📡 mDNS discovery failed: $e');
      return null;
    }
  }

  /// Проверяет доступность сервера
  static Future<bool> checkServer(String url) async {
    try {
      final uri = Uri.parse('$url/health');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      
      final request = await client.getUrl(uri);
      final response = await request.close();
      client.close();
      
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}