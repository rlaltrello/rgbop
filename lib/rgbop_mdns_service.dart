import 'dart:io';
import 'dart:async'; // Required for the timeout
import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:http/http.dart' as http; // Required for the ping

class RGBopMdnsService {
  Future<String?> findPanelIp() async {
    debugPrint("[mDNS] Scanning local network for rgbop.local...");
    String? targetIp;

    // STRATEGY 1: Native OS Resolution
    try {
      final List<InternetAddress> addresses = await InternetAddress
          .lookup('rgbop.local')
          .timeout(const Duration(seconds: 4));
      if (addresses.isNotEmpty) {
        targetIp = addresses.first.address;
        debugPrint("[mDNS] Native lookup found IP: $targetIp");
      }
    } catch (e) {
      debugPrint("[mDNS] Native lookup failed, falling back to UDP multicast...");
    }

    // STRATEGY 2: Dart Multicast DNS (Android Fallback)
    // We completely bypass this on iOS/macOS to prevent the OS Error 65 crash!
    if (targetIp == null && !Platform.isIOS && !Platform.isMacOS) {
      debugPrint("[mDNS] Attempting UDP fallback for Android...");
      final MDnsClient client = MDnsClient(
        rawDatagramSocketFactory: (dynamic host, int port, {bool? reuseAddress, bool? reusePort, int? ttl}) {
          return RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true, reusePort: true);
        },
      );

      try {
        await client.start();
        final results = client
            .lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4('rgbop.local'),
            )
            .timeout(const Duration(seconds: 4));

        await for (final IPAddressResourceRecord record in results) {
          targetIp = record.address.address;
          debugPrint("[mDNS] Found via UDP: $targetIp");
          client.stop();
          break;
        }
      } catch (e) {
        debugPrint("[mDNS] UDP Search Error: $e");
      } finally {
        client.stop();
      }
    }

    // --- THE GHOST BUSTER (VERIFICATION) ---
    // If the OS gave us an IP, we MUST verify the panel is actually online 
    // before we trust it (to avoid caching traps when the panel is in BLE mode).
    if (targetIp != null) {
      debugPrint("[mDNS] Verifying panel is alive at $targetIp...");
      try {
        // Ping the web server with a strict 2-second timeout
        await http.get(Uri.parse('http://$targetIp/')).timeout(const Duration(seconds: 2));
        debugPrint("[mDNS] Panel verified alive!");
        return targetIp; 
      } catch (e) {
        // If it throws a TimeoutException or SocketException, the panel is off Wi-Fi!
        debugPrint("[mDNS] Panel didn't answer. It's a cached ghost!");
        return null; // Return null to force the app into Bluetooth Mode
      }
    }

    return null; // Panel not found
  }
}