import 'dart:io';
import 'dart:async'; // Required for the timeout
import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:http/http.dart' as http; // Required for the ping

class RGBopPanel {
  final String ip;
  final String hostname;
  final String displayName;
  final bool isLegacyDiscovery;

  const RGBopPanel({
    required this.ip,
    required this.hostname,
    required this.displayName,
    this.isLegacyDiscovery = false,
  });
}

class RGBopMdnsService {
  Future<List<RGBopPanel>> discoverPanels() async {
    final completer = Completer<List<RGBopPanel>>();

    runZonedGuarded(() async {
      try {
        final discovered = await _discoverPanelsViaMdns();
        if (!completer.isCompleted) completer.complete(discovered);
      } catch (e, st) {
        debugPrint('[mDNS] discoverPanels failed: $e');
        debugPrint('$st');
        if (!completer.isCompleted) completer.complete(const []);
      }
    }, (error, stackTrace) {
      debugPrint('[mDNS] uncaught discovery error: $error');
      debugPrint('$stackTrace');
      if (!completer.isCompleted) completer.complete(const []);
    });

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        debugPrint('[mDNS] discovery timed out');
        return const [];
      },
    );
  }

  Future<List<RGBopPanel>> _discoverPanelsViaMdns() async {
    final client = _createMdnsClient();
    final byIp = <String, RGBopPanel>{};

    try {
      await client.start();

      final ptrRecords = await _collectLookup<PtrResourceRecord>(
        client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('_http._tcp.local'),
        ),
        const Duration(seconds: 3),
      );

      final rgbopServices = ptrRecords
          .map((r) => r.domainName)
          .where((name) => name.toLowerCase().contains('rgbop'))
          .toSet();

      for (final serviceName in rgbopServices) {
        final srvRecords = await _collectLookup<SrvResourceRecord>(
          client.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(serviceName),
          ),
          const Duration(seconds: 2),
        );

        for (final srv in srvRecords) {
          if (srv.port != 80) continue;

          final targetHost = _trimTrailingDot(srv.target);
          final addressRecords = await _collectLookup<IPAddressResourceRecord>(
            client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(targetHost),
            ),
            const Duration(seconds: 2),
          );

          for (final addr in addressRecords) {
            final ip = addr.address.address;
            if (byIp.containsKey(ip)) continue;

            final isAlive = await _verifyPanelAlive(ip);
            if (!isAlive) continue;

            final friendly = _friendlyNameFromHost(targetHost);
            byIp[ip] = RGBopPanel(
              ip: ip,
              hostname: targetHost,
              displayName: friendly,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[mDNS] Service browse failed: $e');
    } finally {
      try {
        client.stop();
      } catch (e) {
        debugPrint('[mDNS] client.stop error: $e');
      }
    }

    final panels = byIp.values.toList()
      ..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    return panels;
  }

  MDnsClient _createMdnsClient() {
    if (!Platform.isIOS && !Platform.isMacOS) {
      return MDnsClient(
        rawDatagramSocketFactory:
            (
              dynamic host,
              int port, {
              bool? reuseAddress,
              bool? reusePort,
              int? ttl,
            }) {
              return RawDatagramSocket.bind(
                InternetAddress.anyIPv4,
                port,
                reuseAddress: true,
                reusePort: true,
              );
            },
      );
    }
    return MDnsClient();
  }

  Future<List<T>> _collectLookup<T extends ResourceRecord>(
    Stream<T> stream,
    Duration timeout,
  ) async {
    final results = <T>[];
    StreamSubscription<T>? subscription;
    final done = Completer<void>();
    Timer? timer;

    try {
      subscription = stream.listen(
        (record) {
          results.add(record);
        },
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('[mDNS] lookup stream error: $error');
          debugPrint('$stackTrace');
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: false,
      );

      timer = Timer(timeout, () {
        if (!done.isCompleted) done.complete();
      });

      await done.future;
    } catch (e, st) {
      // Lookup errors are expected on noisy networks, but we still log for diagnosis.
      debugPrint('[mDNS] lookup setup error: $e');
      debugPrint('$st');
    } finally {
      timer?.cancel();
      try {
        await subscription?.cancel();
      } catch (e) {
        debugPrint('[mDNS] subscription cancel error: $e');
      }
    }

    return results;
  }

  String _trimTrailingDot(String host) {
    if (host.endsWith('.')) return host.substring(0, host.length - 1);
    return host;
  }

  String _friendlyNameFromHost(String host) {
    final lower = host.toLowerCase();
    if (lower.endsWith('.local')) {
      return host.substring(0, host.length - 6);
    }
    return host;
  }

  Future<bool> _verifyPanelAlive(String ip) async {
    try {
      await http
          .get(Uri.parse('http://$ip/'))
          .timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> findPanelIp() async {
    debugPrint('[mDNS] Resolving panel IP from discovered panel list...');
    try {
      final panels = await discoverPanels();
      if (panels.isEmpty) return null;
      return panels.first.ip;
    } catch (e, st) {
      debugPrint('[mDNS] findPanelIp failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  Future<RGBopPanel?> resolvePanelByHost(String hostOrIp) async {
    final candidate = hostOrIp.trim();
    if (candidate.isEmpty) return null;

    String resolvedIp = candidate;
    String resolvedHost = candidate;

    final isIpAddress = RegExp(
      r'^\d{1,3}(?:\.\d{1,3}){3}$',
    ).hasMatch(candidate);

    if (!isIpAddress) {
      try {
        final addresses = await InternetAddress.lookup(
          candidate,
        ).timeout(const Duration(seconds: 4));
        if (addresses.isEmpty) return null;
        resolvedIp = addresses.first.address;
      } catch (_) {
        return null;
      }
    }

    try {
      await http
          .get(Uri.parse('http://$resolvedIp/'))
          .timeout(const Duration(seconds: 2));
      return RGBopPanel(
        ip: resolvedIp,
        hostname: resolvedHost,
        displayName: resolvedHost,
      );
    } catch (_) {
      return null;
    }
  }
}
