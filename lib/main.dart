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
        '/setup': (context) => SetupScreen(), // Setup is now explicitly '/setup'
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
  @override
  void initState() {
    super.initState();
    _routeApp();
  }

  Future<void> _routeApp() async {
    // 1. Look for the panel on the local network
    final mdns = RGBopMdnsService();
    String? ip = await mdns.findPanelIp();

    if (mounted) {
      if (ip != null) {
        // Panel found! Bypass BLE and go straight to the dashboard.
        Navigator.pushReplacementNamed(context, '/dashboard');
      } else {
        // Not found. Fall back to the BLE setup screen.
        Navigator.pushReplacementNamed(context, '/setup');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // This shows briefly while scanning the network
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.blueAccent),
            SizedBox(height: 20),
            Text("Searching for panel...", style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}