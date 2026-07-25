import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'offline_studio_screen.dart';
import 'setup_screen.dart';
import 'dashboard_screen.dart';
import 'spotify_auth_callback_controller.dart';
import 'rgbop_mdns_service.dart'; // Add your mDNS service here

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SpotifyAuthCallbackController.instance.init();
  runApp(const RGBopApp());
}

class RGBopApp extends StatelessWidget {
  const RGBopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RGBop',
      debugShowCheckedModeBanner: false,

      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: Colors.blueAccent,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
        ),
        useMaterial3: true,
      ),

      // Point the initial route to our new BootRouter instead of Setup
      initialRoute: '/',
      routes: {
        '/': (context) => const BootRouter(),
        '/setup': (context) =>
            SetupScreen(), // Setup is now explicitly '/setup'
        '/dashboard': (context) => const DashboardScreen(),
        '/offline': (context) => const OfflineStudioScreen(),
      },
    );
  }
}

// --- THE TRAFFIC COP ---
class BootRouter extends StatefulWidget {
  const BootRouter({super.key});

  @override
  State<BootRouter> createState() => _BootRouterState();
}

class _BootRouterState extends State<BootRouter> {
  static const String _recentHostsKey = 'recent_successful_hosts';
  static const int _maxRecentHosts = 8;

  final RGBopMdnsService _mdnsService = RGBopMdnsService();
  final TextEditingController _manualHostCtrl = TextEditingController();
  List<RGBopPanel> _panels = const [];
  List<String> _recentHosts = const [];
  bool _isScanning = true;
  bool _isManualConnecting = false;
  String? _scanError;

  @override
  void initState() {
    super.initState();
    _loadRecentHosts();
    _refreshPanels();
  }

  Future<void> _loadRecentHosts() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_recentHostsKey) ?? const [];
    for (final host in saved) {
      _mdnsService.addDiscoveryHint(host);
    }
    if (!mounted) return;
    setState(() {
      _recentHosts = saved;
    });
  }

  Future<void> _rememberHost(String hostOrIp) async {
    final value = hostOrIp.trim();
    if (value.isEmpty) return;
    _mdnsService.addDiscoveryHint(value);

    final current = _recentHosts
        .where((h) => h.toLowerCase() != value.toLowerCase())
        .toList();
    current.insert(0, value);
    if (current.length > _maxRecentHosts) {
      current.removeRange(_maxRecentHosts, current.length);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentHostsKey, current);

    if (!mounted) return;
    setState(() {
      _recentHosts = current;
    });
  }

  Future<void> _removeRememberedHost(String hostOrIp) async {
    final updated = _recentHosts
        .where((h) => h.toLowerCase() != hostOrIp.toLowerCase())
        .toList();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentHostsKey, updated);

    if (!mounted) return;
    setState(() {
      _recentHosts = updated;
    });
  }

  Future<void> _refreshPanels() async {
    setState(() {
      _isScanning = true;
      _scanError = null;
    });

    try {
      final panels = await _mdnsService.discoverPanels();
      if (!mounted) return;
      setState(() {
        _panels = panels;
        _isScanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _panels = const [];
        _isScanning = false;
        _scanError = 'Scan failed. Pull refresh and try again.';
      });
    }
  }

  @override
  void dispose() {
    _manualHostCtrl.dispose();
    super.dispose();
  }

  Future<void> _connectManualHost() async {
    final input = _manualHostCtrl.text.trim();
    if (input.isEmpty) return;

    setState(() => _isManualConnecting = true);
    try {
      final panel = await _mdnsService.resolvePanelByHost(input);
      if (!mounted) return;

      if (panel == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not reach that host/IP. Check and try again.'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      await _rememberHost(input);
      _selectPanel(panel);
    } finally {
      if (mounted) {
        setState(() => _isManualConnecting = false);
      }
    }
  }

  void _selectPanel(RGBopPanel panel) {
    _rememberHost(panel.hostname);
    _rememberHost(panel.ip);
    Navigator.pushReplacementNamed(context, '/dashboard', arguments: panel.ip);
  }

  Future<void> _connectRememberedHost(String hostOrIp) async {
    _manualHostCtrl.text = hostOrIp;
    await _connectManualHost();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose Panel'),
        actions: [
          IconButton(
            onPressed: _isScanning ? null : _refreshPanels,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh scan',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshPanels,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Panels on WiFi',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Discovery can be inconsistent. Refresh until the panel you want appears, then tap it.',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _manualHostCtrl,
              decoration: InputDecoration(
                labelText: 'Manual Hostname/IP',
                hintText: 'rgbop-90A994.local or 192.168.1.45',
                border: const OutlineInputBorder(),
                suffixIcon: _isManualConnecting
                    ? const Padding(
                        padding: EdgeInsets.all(12.0),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.login),
                        tooltip: 'Connect',
                        onPressed: _connectManualHost,
                      ),
              ),
              onSubmitted: (_) => _connectManualHost(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.amber),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.pushNamed(context, '/offline'),
                icon: const Icon(Icons.offline_bolt, color: Colors.amber),
                label: const Text(
                  'Work Offline (Local GIFs & Doodles)',
                  style: TextStyle(color: Colors.amber),
                ),
              ),
            ),
            if (_recentHosts.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Recent successful addresses',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              ..._recentHosts.map(
                (host) => Card(
                  color: const Color(0xFF1A1A1A),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.history,
                      color: Colors.blueAccent,
                    ),
                    title: Text(host),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Use this address',
                          icon: const Icon(
                            Icons.login,
                            color: Colors.blueAccent,
                          ),
                          onPressed: _isManualConnecting
                              ? null
                              : () => _connectRememberedHost(host),
                        ),
                        IconButton(
                          tooltip: 'Remove from history',
                          icon: const Icon(Icons.close, color: Colors.grey),
                          onPressed: () => _removeRememberedHost(host),
                        ),
                      ],
                    ),
                    onTap: _isManualConnecting
                        ? null
                        : () => _connectRememberedHost(host),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            if (_isScanning) ...[
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: CircularProgressIndicator(color: Colors.blueAccent),
                ),
              ),
              const Center(
                child: Text(
                  'Scanning for panels...',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ] else if (_panels.isNotEmpty) ...[
              ..._panels.map(
                (panel) => Card(
                  color: const Color(0xFF1E1E1E),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: const Icon(Icons.dns, color: Colors.blueAccent),
                    title: Text(panel.displayName),
                    subtitle: Text('${panel.hostname}  |  ${panel.ip}'),
                    trailing: panel.isLegacyDiscovery
                        ? const Icon(
                            Icons.history_toggle_off,
                            color: Colors.grey,
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: () => _selectPanel(panel),
                  ),
                ),
              ),
            ] else ...[
              const Icon(Icons.wifi_off, color: Colors.redAccent, size: 64),
              const SizedBox(height: 16),
              const Text(
                'No panels found yet.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _scanError ??
                    'Refresh a few times. ESP32 discovery may take more than one scan.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  label: const Text(
                    'Refresh Scan',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  onPressed: _refreshPanels,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.blueAccent),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  icon: const Icon(Icons.bluetooth, color: Colors.blueAccent),
                  label: const Text(
                    'Set Up New Panel',
                    style: TextStyle(color: Colors.blueAccent, fontSize: 16),
                  ),
                  onPressed: () {
                    Navigator.pushReplacementNamed(context, '/setup');
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
