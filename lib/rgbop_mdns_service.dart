import 'dart:io';
import 'dart:async'; // Required for the timeout
import 'dart:convert';
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
  bool _lastScanHadSocketLookupError = false;
  static DateTime? _globalBlockedUntil;
  static Future<List<RGBopPanel>>? _inFlightDiscovery;
  static Future<List<RGBopPanel>>? _inFlightSubnetProbe;
  static DateTime? _lastSubnetProbeAt;
  static final Set<String> _hostFallbackHints = {
    'rgbop.local',
    'rgbop-setup.local',
  };

  static final RegExp _ipv4Pattern = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

  static const Duration _socketRouteBackoff = Duration(seconds: 20);
  static const Duration _subnetProbeCooldown = Duration(seconds: 30);

  void addDiscoveryHint(String hostOrIp) {
    final normalized = hostOrIp.trim().toLowerCase();
    if (normalized.isEmpty) return;

    _hostFallbackHints.add(normalized);

    final isIpAddress = _ipv4Pattern.hasMatch(normalized);
    if (!isIpAddress && !normalized.contains('.')) {
      _hostFallbackHints.add('$normalized.local');
    }
  }

  Future<List<RGBopPanel>> discoverPanels() async {
    final existingDiscovery = _inFlightDiscovery;
    if (existingDiscovery != null) {
      return existingDiscovery;
    }

    final discoveryFuture = _discoverPanelsInternal();
    _inFlightDiscovery = discoveryFuture;

    try {
      return await discoveryFuture;
    } finally {
      if (identical(_inFlightDiscovery, discoveryFuture)) {
        _inFlightDiscovery = null;
      }
    }
  }

  Future<List<RGBopPanel>> _discoverPanelsInternal() async {
    if (Platform.isIOS &&
        _globalBlockedUntil != null &&
        DateTime.now().isBefore(_globalBlockedUntil!)) {
      final hostFallback = await _discoverPanelsViaHostnameFallback();
      if (hostFallback.isNotEmpty) {
        debugPrint(
          '[mDNS] iOS hostname fallback found ${hostFallback.length} panel(s) while multicast scan is paused.',
        );
        return hostFallback;
      }

      final subnetFallback = await _discoverPanelsViaSubnetProbeCached();
      if (subnetFallback.isNotEmpty) {
        debugPrint(
          '[mDNS] iOS subnet fallback found ${subnetFallback.length} panel(s) while multicast scan is paused.',
        );
        return subnetFallback;
      }
      return const [];
    }

    try {
      final discovered = await _discoverPanelsViaMdns().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[mDNS] discovery timed out');
          return const [];
        },
      );

      if (Platform.isIOS && discovered.isEmpty) {
        final hostFallback = await _discoverPanelsViaHostnameFallback();
        if (hostFallback.isNotEmpty) {
          debugPrint(
            '[mDNS] iOS hostname fallback found ${hostFallback.length} panel(s).',
          );
          return hostFallback;
        }

        final subnetFallback = await _discoverPanelsViaSubnetProbeCached();
        if (subnetFallback.isNotEmpty) {
          debugPrint(
            '[mDNS] iOS subnet fallback found ${subnetFallback.length} panel(s).',
          );
          return subnetFallback;
        }

        if (_lastScanHadSocketLookupError) {
          debugPrint(
            '[mDNS] iOS primary scan hit socket routing errors; skipping fallback for this pass.',
          );
          return const [];
        }
        debugPrint(
          '[mDNS] iOS primary scan returned no panels; trying fallback scan...',
        );
        return _discoverPanelsViaIosFallback();
      }

      return discovered;
    } catch (e, st) {
      debugPrint('[mDNS] discoverPanels failed: $e');
      debugPrint('$st');
      if (e is SocketException) {
        _noteSocketRoutingIssue(e);
      }
      if (Platform.isIOS) {
        final hostFallback = await _discoverPanelsViaHostnameFallback();
        if (hostFallback.isNotEmpty) {
          debugPrint(
            '[mDNS] iOS hostname fallback found ${hostFallback.length} panel(s).',
          );
          return hostFallback;
        }

        final subnetFallback = await _discoverPanelsViaSubnetProbeCached();
        if (subnetFallback.isNotEmpty) {
          debugPrint(
            '[mDNS] iOS subnet fallback found ${subnetFallback.length} panel(s).',
          );
          return subnetFallback;
        }

        if (_lastScanHadSocketLookupError) {
          return const [];
        }
        return _discoverPanelsViaIosFallback();
      }
      return const [];
    }
  }

  Future<List<RGBopPanel>> _discoverPanelsViaMdns({
    MDnsClient? clientOverride,
    Duration ptrTimeout = const Duration(seconds: 3),
    Duration srvTimeout = const Duration(seconds: 2),
    Duration addrTimeout = const Duration(seconds: 2),
  }) async {
    final zoneResult = Completer<List<RGBopPanel>>();

    runZonedGuarded(
      () async {
        final client = clientOverride ?? _createMdnsClient();
        final byIp = <String, RGBopPanel>{};
        _lastScanHadSocketLookupError = false;

        try {
          await client.start();

          final ptrRecords = await _safeLookup<PtrResourceRecord>(
            label: 'PTR _http._tcp.local',
            streamFactory: () => client.lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer('_http._tcp.local'),
            ),
            timeout: ptrTimeout,
            onSocketError: () => _lastScanHadSocketLookupError = true,
          );

          final rgbopServices = ptrRecords
              .map((r) => r.domainName)
              .where((name) => name.toLowerCase().contains('rgbop'))
              .toSet();

          for (final serviceName in rgbopServices) {
            final srvRecords = await _safeLookup<SrvResourceRecord>(
              label: 'SRV $serviceName',
              streamFactory: () => client.lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(serviceName),
              ),
              timeout: srvTimeout,
              onSocketError: () => _lastScanHadSocketLookupError = true,
            );

            for (final srv in srvRecords) {
              if (srv.port != 80) continue;

              final targetHost = _trimTrailingDot(srv.target);
              final addressRecords = await _safeLookup<IPAddressResourceRecord>(
                label: 'A $targetHost',
                streamFactory: () => client.lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv4(targetHost),
                ),
                timeout: addrTimeout,
                onSocketError: () => _lastScanHadSocketLookupError = true,
              );

              for (final addr in addressRecords) {
                final ip = addr.address.address;
                if (byIp.containsKey(ip)) continue;

                final isAlive = await _verifyPanelAlive(ip);
                if (!isAlive) continue;

                final friendlyHost = _friendlyNameFromHost(targetHost);
                final settingsName = await _readPanelNameFromSettings(ip);
                byIp[ip] = RGBopPanel(
                  ip: ip,
                  hostname: targetHost,
                  displayName: settingsName ?? friendlyHost,
                );
              }
            }
          }
        } catch (e, st) {
          debugPrint('[mDNS] Service browse failed: $e');
          debugPrint('$st');
        } finally {
          try {
            client.stop();
          } catch (e) {
            debugPrint('[mDNS] client.stop error: $e');
          }
        }

        final panels = byIp.values.toList()
          ..sort(
            (a, b) => a.displayName.toLowerCase().compareTo(
              b.displayName.toLowerCase(),
            ),
          );
        if (!zoneResult.isCompleted) {
          zoneResult.complete(panels);
        }
      },
      (error, stackTrace) {
        if (error is SocketException) {
          _noteSocketRoutingIssue(error);
        } else {
          debugPrint('[mDNS] guarded discovery error: $error');
          debugPrint('$stackTrace');
        }
        if (!zoneResult.isCompleted) {
          zoneResult.complete(const []);
        }
      },
    );

    return zoneResult.future;
  }

  Future<List<T>> _safeLookup<T extends ResourceRecord>({
    required String label,
    required Stream<T> Function() streamFactory,
    required Duration timeout,
    VoidCallback? onSocketError,
  }) async {
    try {
      return await _collectLookup<T>(streamFactory(), timeout);
    } on SocketException catch (e) {
      onSocketError?.call();
      _noteSocketRoutingIssue(e, label: label);
      return const [];
    } catch (e, st) {
      debugPrint('[mDNS] lookup failure during $label: $e');
      debugPrint('$st');
      return const [];
    }
  }

  void _noteSocketRoutingIssue(SocketException error, {String? label}) {
    _lastScanHadSocketLookupError = true;
    _globalBlockedUntil = DateTime.now().add(_socketRouteBackoff);
    if (label != null) {
      debugPrint('[mDNS] socket route issue during $label: $error');
    } else {
      debugPrint('[mDNS] socket route issue: $error');
    }
    debugPrint(
      '[mDNS] iOS mDNS scanning paused for ${_socketRouteBackoff.inSeconds}s after route failure.',
    );
  }

  Future<List<RGBopPanel>> _discoverPanelsViaHostnameFallback() async {
    final byIp = <String, RGBopPanel>{};
    final hostCandidates = _hostFallbackHints.toList();

    for (final host in hostCandidates) {
      final resolved = await resolvePanelByHost(host);
      if (resolved == null) {
        debugPrint('[mDNS] hostname fallback miss: $host');
        continue;
      }

      byIp[resolved.ip] = RGBopPanel(
        ip: resolved.ip,
        hostname: resolved.hostname,
        displayName:
            await _readPanelNameFromSettings(resolved.ip) ??
            _friendlyNameFromHost(resolved.hostname),
      );
    }

    return byIp.values.toList()..sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
  }

  Future<List<RGBopPanel>> _discoverPanelsViaSubnetProbeCached() async {
    final existing = _inFlightSubnetProbe;
    if (existing != null) {
      return existing;
    }

    if (_lastSubnetProbeAt != null &&
        DateTime.now().difference(_lastSubnetProbeAt!) < _subnetProbeCooldown) {
      return const [];
    }

    final probeFuture = _discoverPanelsViaSubnetProbe();
    _inFlightSubnetProbe = probeFuture;

    try {
      final found = await probeFuture;
      _lastSubnetProbeAt = DateTime.now();
      return found;
    } finally {
      if (identical(_inFlightSubnetProbe, probeFuture)) {
        _inFlightSubnetProbe = null;
      }
    }
  }

  Future<List<RGBopPanel>> _discoverPanelsViaSubnetProbe() async {
    final prefixes = <String>{};
    final knownIps = <String>{
      for (final hint in _hostFallbackHints)
        if (_ipv4Pattern.hasMatch(hint)) hint,
    };

    for (final ip in knownIps) {
      final parts = ip.split('.');
      if (parts.length == 4) {
        prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
      }
    }

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          if (!_ipv4Pattern.hasMatch(ip)) continue;
          final parts = ip.split('.');
          if (parts.length != 4) continue;
          final p0 = int.tryParse(parts[0]) ?? -1;
          final p1 = int.tryParse(parts[1]) ?? -1;
          final isPrivate =
              p0 == 10 ||
              (p0 == 172 && p1 >= 16 && p1 <= 31) ||
              (p0 == 192 && p1 == 168);
          if (!isPrivate) continue;
          prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
        }
      }
    } catch (_) {
      // Best effort only.
    }

    if (prefixes.isEmpty) {
      return const [];
    }

    final candidates = <String>[];
    for (final prefix in prefixes) {
      for (var host = 1; host <= 254; host++) {
        candidates.add('$prefix.$host');
      }
    }

    final found = <String, RGBopPanel>{};

    for (var i = 0; i < candidates.length; i += 24) {
      final chunk = candidates.skip(i).take(24).toList();
      final results = await Future.wait(
        chunk.map(_probePanelSettings),
        eagerError: false,
      );
      for (final panel in results) {
        if (panel == null) continue;
        found[panel.ip] = panel;
      }
      if (found.length >= 6) {
        break;
      }
    }

    final panels = found.values.toList()
      ..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    return panels;
  }

  Future<RGBopPanel?> _probePanelSettings(String ip) async {
    try {
      final response = await http
          .get(Uri.parse('http://$ip/api/settings'))
          .timeout(const Duration(milliseconds: 700));

      if (response.statusCode != 200) return null;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      if (!decoded.containsKey('gifs') || !decoded.containsKey('clock')) {
        return null;
      }

      addDiscoveryHint(ip);
      final panelName = _parsePanelNameFromSettings(decoded);
      return RGBopPanel(
        ip: ip,
        hostname: ip,
        displayName: panelName ?? 'rgbop-$ip',
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readPanelNameFromSettings(String ip) async {
    try {
      final response = await http
          .get(Uri.parse('http://$ip/api/settings'))
          .timeout(const Duration(milliseconds: 700));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      return _parsePanelNameFromSettings(decoded);
    } catch (_) {
      return null;
    }
  }

  String? _parsePanelNameFromSettings(Map<String, dynamic> data) {
    final raw = data['panelName'] ?? data['name'];
    if (raw == null) return null;
    final name = raw.toString().trim();
    if (name.isEmpty) return null;
    return name;
  }

  Future<List<RGBopPanel>> _discoverPanelsViaIosFallback() async {
    try {
      final fallback = await _discoverPanelsViaMdns(
        clientOverride: _createFallbackMdnsClient(),
        ptrTimeout: const Duration(seconds: 2),
        srvTimeout: const Duration(seconds: 2),
        addrTimeout: const Duration(seconds: 2),
      );
      debugPrint('[mDNS] iOS fallback scan found ${fallback.length} panel(s).');
      return fallback;
    } catch (e, st) {
      debugPrint('[mDNS] iOS fallback scan failed: $e');
      debugPrint('$st');
      return const [];
    }
  }

  MDnsClient _createMdnsClient() {
    if (!Platform.isIOS && !Platform.isMacOS) {
      return _createFallbackMdnsClient();
    }
    return MDnsClient();
  }

  MDnsClient _createFallbackMdnsClient() {
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
      addDiscoveryHint(resolvedHost);
      addDiscoveryHint(resolvedIp);
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
