import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'rgbop_mdns_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final RGBopMdnsService _mdnsService = RGBopMdnsService();
  bool _isResetting = false;

  Future<void> _factoryResetPanel() async {
    setState(() => _isResetting = true);

    try {
      // 1. Find the panel on the local network using the mDNS service we wrote
      debugPrint("[App] Searching for rgbop.local...");
      String? ipAddress = await _mdnsService.findPanelIp();

      if (ipAddress == null) {
        _showError("Could not find the RGBop panel on the network.");
        setState(() => _isResetting = false);
        return;
      }

      // 2. Send the Kill Command to the ESP32 Web Server
      debugPrint("[App] Sending reset command to http://$ipAddress/api/reset");
      final response = await http.post(
        Uri.parse('http://$ipAddress/api/reset'),
      );

      if (response.statusCode == 200) {
        debugPrint("[App] Reset successful! Returning to Setup Screen.");
        if (mounted) {
          // Push the user back to the BLE scanner screen
          Navigator.pushReplacementNamed(context, '/'); 
        }
      } else {
        _showError("Panel rejected the command: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Network error: $e");
    }

    if (mounted) {
      setState(() => _isResetting = false);
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("RGBop Dashboard")),
      body: Center(
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          ),
          onPressed: _isResetting ? null : _factoryResetPanel,
          icon: _isResetting 
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white)) 
              : const Icon(Icons.warning_amber_rounded, color: Colors.white),
          label: const Text(
            "FACTORY RESET PANEL", 
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)
          ),
        ),
      ),
    );
  }
}