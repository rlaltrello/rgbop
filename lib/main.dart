import 'package:flutter/material.dart';
import 'setup_screen.dart';
import 'dashboard_screen.dart';
import 'rgbop_mdns_service.dart'; // Add your mDNS service here

void main() {
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
  bool _connectionFailed = false;
  String _statusText = "Searching for panel on WiFi...";

  @override
  void initState() {
    super.initState();
    _attemptConnection();
  }

  Future<void> _attemptConnection() async {
    // Reset state for retries
    setState(() {
      _connectionFailed = false;
      _statusText = "Searching for panel on WiFi...";
    });

    // 1. Look for the panel on the local network
    final mdns = RGBopMdnsService();
    String? ip;
    try {
      ip = await mdns.findPanelIp().timeout(const Duration(seconds: 8));
    } catch (_) {
      ip = null;
    }

    if (!mounted) return;

    if (ip != null) {
      // Panel found! Show the dopamine-hit success message
      setState(() {
        _statusText = "Found panel! Enumerating services...";
      });

      // Pause just long enough for the user to read it
      await Future.delayed(const Duration(milliseconds: 300));

      if (mounted) {
        // Bypass BLE and go straight to the dashboard.
        Navigator.pushReplacementNamed(context, '/dashboard', arguments: ip);
      }
    } else {
      // Not found. Stop searching and show the retry buttons.
      setState(() {
        _connectionFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: _connectionFailed ? _buildFailureUI() : _buildLoadingUI(),
        ),
      ),
    );
  }

  Widget _buildLoadingUI() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(color: Colors.blueAccent),
        const SizedBox(height: 24),
        Text(
          _statusText,
          style: const TextStyle(color: Colors.grey, fontSize: 16),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildFailureUI() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.wifi_off, color: Colors.redAccent, size: 64),
        const SizedBox(height: 16),
        const Text(
          "Could not find RGBop on the network.",
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        const Text(
          "Ensure your phone is on the same WiFi network, or set up a new panel.",
          style: TextStyle(color: Colors.grey, fontSize: 14),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),

        // Button 1: Retry WiFi
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            icon: const Icon(Icons.refresh, color: Colors.white),
            label: const Text(
              "Retry Existing Panel",
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            onPressed: _attemptConnection,
          ),
        ),
        const SizedBox(height: 16),

        // Button 2: Fallback to Bluetooth Setup
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.blueAccent),
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            icon: const Icon(Icons.bluetooth, color: Colors.blueAccent),
            label: const Text(
              "Set Up New Panel",
              style: TextStyle(color: Colors.blueAccent, fontSize: 16),
            ),
            onPressed: () {
              // Navigate to the Setup route manually
              Navigator.pushReplacementNamed(context, '/setup');
            },
          ),
        ),
      ],
    );
  }
}
