import 'package:multicast_dns/multicast_dns.dart';
import 'package:flutter/foundation.dart';

class RGBopMdnsService {
  String? matrixIpAddress;

  Future<String?> findPanelIp() async {
    const String targetName = 'rgbop.local';
    
    debugPrint("[mDNS] Scanning local network for $targetName...");
    
    final MDnsClient client = MDnsClient();
    await client.start();

    try {
      // Look for A records (IPv4 addresses) matching rgbop.local
      await for (final IPAddressResourceRecord record in 
          client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(targetName))) {
        
        debugPrint("[mDNS] Found RGBop Panel at: ${record.address.address}");
        matrixIpAddress = record.address.address;
        
        client.stop();
        return matrixIpAddress;
      }
    } catch (e) {
      debugPrint("[mDNS] Error during scan: $e");
    }

    client.stop();
    debugPrint("[mDNS] Panel not found on local network.");
    return null;
  }
}