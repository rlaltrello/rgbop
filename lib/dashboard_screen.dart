import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'rgbop_mdns_service.dart';
import 'gif_manager_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final RGBopMdnsService _mdnsService = RGBopMdnsService();
  String? _panelIp;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isResetting = false;

  // --- Settings State ---
  bool _showClock = true;
  bool _showGifs = true;
  bool _showDate = true;
  bool _showWeather = true;
  bool _showISS = true;
  bool _showPlanes = true;
  bool _showTextBlast = true;

  final TextEditingController _latCtrl = TextEditingController();
  final TextEditingController _lngCtrl = TextEditingController();
  final TextEditingController _osUserCtrl = TextEditingController();
  final TextEditingController _osPassCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initDashboard();
  }

  Future<void> _initDashboard() async {
    // 1. Find the IP once when the dashboard loads
    String? ip = await _mdnsService.findPanelIp();
    
    if (ip == null) {
      if (mounted) Navigator.pushReplacementNamed(context, '/setup');
      return;
    }
    
    _panelIp = ip;
    await _fetchSettings();
  }

  Future<void> _fetchSettings() async {
    try {
      final response = await http.get(Uri.parse('http://$_panelIp/api/settings'));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _showGifs = data['gifs'] ?? true;
          _showClock = data['clock'] ?? true;
          _showDate = data['date'] ?? true;
          _showWeather = data['weather'] ?? true;
          _showISS = data['iss'] ?? true;
          _showPlanes = data['planes'] ?? true;
          _showTextBlast = data['textblast'] ?? true;
          
          _latCtrl.text = (data['lat'] ?? 34.16).toString();
          _lngCtrl.text = (data['lng'] ?? -84.80).toString();
          _osUserCtrl.text = data['osUser'] ?? '';
          _osPassCtrl.text = data['osPass'] ?? '';
          _isLoading = false;
        });
      }
    } catch (e) {
      _showError("Failed to load panel settings.");
    }
  }

  Future<void> _saveSettings() async {
    if (_panelIp == null) return;
    
    setState(() => _isSaving = true);
    try {
      final body = jsonEncode({
        "gifs": _showGifs,
        "clock": _showClock,
        "date": _showDate,
        "weather": _showWeather,
        "iss": _showISS,
        "planes": _showPlanes,
        "textblast": _showTextBlast,
        "lat": double.tryParse(_latCtrl.text) ?? 34.16,
        "lng": double.tryParse(_lngCtrl.text) ?? -84.80,
        "osUser": _osUserCtrl.text,
        "osPass": _osPassCtrl.text
      });

      final response = await http.post(
        Uri.parse('http://$_panelIp/api/settings'),
        headers: {"Content-Type": "application/json"},
        body: body,
      );

      if (response.statusCode == 200) {
        _showSuccess("Settings saved to panel!");
      } else {
        _showError("Save failed: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Network error while saving.");
    }
    setState(() => _isSaving = false);
  }

  Future<void> _factoryResetPanel() async {
    if (_panelIp == null) return;
    setState(() => _isResetting = true);

    try {
      final response = await http.post(Uri.parse('http://$_panelIp/api/reset'));
      if (response.statusCode == 200) {
        if (mounted) Navigator.pushReplacementNamed(context, '/');
      } else {
        _showError("Panel rejected the command.");
      }
    } catch (e) {
      _showError("Network error. Panel might already be rebooting.");
      if (mounted) Navigator.pushReplacementNamed(context, '/');
    }
    if (mounted) setState(() => _isResetting = false);
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.red));
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.green));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("RGBop Control"),
        actions: [
          _isSaving
              ? const Padding(padding: EdgeInsets.all(16.0), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(icon: const Icon(Icons.save, color: Colors.blueAccent), onPressed: _saveSettings),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- WIDGET TOGGLES ---
          Card(
            color: const Color(0xFF1E1E1E),
            child: Column(
              children: [
                const ListTile(
                  title: Text("Active Widgets", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                  leading: Icon(Icons.dashboard, color: Colors.blueAccent),
                ),
                SwitchListTile(title: const Text("GIFs"), value: _showGifs, onChanged: (v) => setState(() => _showGifs = v)),
                SwitchListTile(title: const Text("Clocks"), value: _showClock, onChanged: (v) => setState(() => _showClock = v)),
                SwitchListTile(title: const Text("Date Progress"), value: _showDate, onChanged: (v) => setState(() => _showDate = v)),
                SwitchListTile(title: const Text("Weather"), value: _showWeather, onChanged: (v) => setState(() => _showWeather = v)),
                SwitchListTile(title: const Text("ISS Tracker"), value: _showISS, onChanged: (v) => setState(() => _showISS = v)),
                SwitchListTile(title: const Text("Planes"), value: _showPlanes, onChanged: (v) => setState(() => _showPlanes = v)),
                SwitchListTile(title: const Text("Text Blast"), value: _showTextBlast, onChanged: (v) => setState(() => _showTextBlast = v)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // --- MEDIA MANAGEMENT ---
          Card(
            color: const Color(0xFF1E1E1E),
            child: ListTile(
              leading: const Icon(Icons.gif_box, color: Colors.blueAccent),
              title: const Text("Manage GIFs", style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text("Upload and delete panel animations"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                if (_panelIp != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => GifManagerScreen(panelIp: _panelIp!),
                    ),
                  );
                }
              },
            ),
          ),
          const SizedBox(height: 16),
          // --- LOCATION ---
          Card(
            color: const Color(0xFF1E1E1E),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  const Row(
                    children: [
                      Icon(Icons.location_on, color: Colors.blueAccent),
                      SizedBox(width: 16),
                      Text("Location Settings", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(controller: _latCtrl, decoration: const InputDecoration(labelText: "Latitude", border: OutlineInputBorder()), keyboardType: TextInputType.number),
                  const SizedBox(height: 16),
                  TextField(controller: _lngCtrl, decoration: const InputDecoration(labelText: "Longitude", border: OutlineInputBorder()), keyboardType: TextInputType.number),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // --- OPENSKY ---
          Card(
            color: const Color(0xFF1E1E1E),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  const Row(
                    children: [
                      Icon(Icons.flight, color: Colors.blueAccent),
                      SizedBox(width: 16),
                      Text("OpenSky API", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(controller: _osUserCtrl, decoration: const InputDecoration(labelText: "Username", border: OutlineInputBorder())),
                  const SizedBox(height: 16),
                  TextField(controller: _osPassCtrl, decoration: const InputDecoration(labelText: "Password", border: OutlineInputBorder()), obscureText: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          // --- DANGER ZONE ---
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent.withValues(alpha: 0.2),
              foregroundColor: Colors.redAccent,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: _isResetting ? null : _factoryResetPanel,
            icon: _isResetting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator()) : const Icon(Icons.warning_amber_rounded),
            label: const Text("FACTORY RESET PANEL", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}