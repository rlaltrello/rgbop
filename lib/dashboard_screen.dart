import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'rgbop_mdns_service.dart';
import 'gif_manager_screen.dart';
import 'package:geolocator/geolocator.dart';
import 'doodle_gallery.dart';

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
  bool _showDoodles = true;
  double _brightness = 128;
  bool _nightMode = false;
  int _nightStart = 22;
  int _nightEnd = 6;
  bool _isFetchingLocation = false;
  int _transitionTime = 10;

  final TextEditingController _latCtrl = TextEditingController();
  final TextEditingController _lngCtrl = TextEditingController();
  final TextEditingController _osUserCtrl = TextEditingController();
  final TextEditingController _osPassCtrl = TextEditingController();
  
  String _formatHour(int h) {
    if (h == 0) return "12 AM";
    if (h == 12) return "12 PM";
    return h > 12 ? "${h - 12} PM" : "$h AM";
  }
  
  Future<void> _getCurrentLocation() async {
    setState(() => _isFetchingLocation = true);
    
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception("Location services are disabled on this device.");
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception("Location permission denied.");
        }
      }
      
      if (permission == LocationPermission.deniedForever) {
        throw Exception("Location permissions are permanently denied. Please enable in settings.");
      }

      // FIX: Use the new locationSettings parameter instead of the deprecated desiredAccuracy
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      setState(() {
        // FIX: Match your specific TextEditingController names
        _latCtrl.text = position.latitude.toStringAsFixed(4);
        _lngCtrl.text = position.longitude.toStringAsFixed(4);
      });
      
    } catch (e) {
      // FIX: Add the mounted check before using context across an async gap
      if (!mounted) return; 
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString(), style: const TextStyle(color: Colors.white)), 
          backgroundColor: Colors.redAccent
        )
      );
    } finally {
      if (mounted) {
        setState(() => _isFetchingLocation = false);
      }
    }
  }

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
          _showDoodles = data['doodles'] ?? true;
          _brightness = (data['brightness'] ?? 128).toDouble();
          _nightMode = data['nightMode'] ?? false;
          _nightStart = data['nightStart'] ?? 22;
          _nightEnd = data['nightEnd'] ?? 6;
          _transitionTime = data['transitionTime'] ?? 10;
          
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
        "doodles": _showDoodles,
        "lat": double.tryParse(_latCtrl.text) ?? 34.16,
        "lng": double.tryParse(_lngCtrl.text) ?? -84.80,
        "osUser": _osUserCtrl.text,
        "osPass": _osPassCtrl.text,
        "brightness": _brightness.toInt(),
        "nightMode": _nightMode,
        "nightStart": _nightStart,
        "nightEnd": _nightEnd,
        "transitionTime": _transitionTime,
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

  Future<void> _confirmFactoryReset() async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false, // Forces the user to explicitly tap a button
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
              SizedBox(width: 8),
              Text("Factory Reset?", style: TextStyle(color: Colors.redAccent)),
            ],
          ),
          content: const Text(
            "This will erase all Wi-Fi settings and preferences on the panel, forcing it back into Bluetooth setup mode. Are you absolutely sure?",
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
              onPressed: () => Navigator.of(context).pop(), // Just close the dialog
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text("Yes, Reset Panel", style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: () {
                Navigator.of(context).pop(); // Close the dialog first
                _factoryResetPanel();        // Then execute the actual reset
              },
            ),
          ],
        );
      },
    );
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
      
      // 1. ADD THE GESTURE DETECTOR HERE TO FIX THE KEYBOARD
      body:ListView(
          padding: const EdgeInsets.all(16),
          children: [
            
            // --- PANEL IP HEADER ---
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0, top: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.wifi, color: Colors.grey, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    "Panel IP = $_panelIp",
                    style: const TextStyle(
                      color: Colors.grey, 
                      fontSize: 14, 
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            
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
                  SwitchListTile(title: const Text("Doodles"), value: _showDoodles, onChanged: (v) => setState(() => _showDoodles = v)),
 
                  const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16.0),
                  child: Divider(color: Colors.white24),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Widget Display Duration", style: TextStyle(color: Colors.white70)),
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: _transitionTime.toDouble(),
                              min: 1,
                              max: 60,
                              divisions: 59,
                              activeColor: Colors.blueAccent,
                              label: "$_transitionTime sec",
                              onChanged: (val) {
                                setState(() => _transitionTime = val.toInt());
                              },
                            ),
                          ),
                          SizedBox(
                            width: 40, // Fixed width prevents jumping as numbers change
                            child: Text(
                              "${_transitionTime}s", 
                              style: const TextStyle(fontWeight: FontWeight.bold),
                              textAlign: TextAlign.right,
                            )
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // --- DISPLAY & BRIGHTNESS ---
            Card(
              color: const Color(0xFF1E1E1E),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.lightbulb_outline, color: Colors.amberAccent),
                        SizedBox(width: 16),
                        Text("Display & Brightness", style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text("Global Brightness"),
                    Slider(
                      value: _brightness,
                      min: 1,
                      max: 255,
                      divisions: 254,
                      activeColor: Colors.amberAccent,
                      label: _brightness.round().toString(),
                      onChanged: (val) {
                        setState(() => _brightness = val);
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Night Mode (Dim to Near Zero)"),
                      activeThumbColor: Colors.amberAccent,
                      value: _nightMode,
                      onChanged: (val) => setState(() => _nightMode = val),
                    ),
                    if (_nightMode) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Quiet Hours:"),
                          DropdownButton<int>(
                            value: _nightStart,
                            dropdownColor: const Color(0xFF2A2A2A),
                            items: List.generate(24, (i) => DropdownMenuItem(value: i, child: Text(_formatHour(i)))),
                            onChanged: (val) => setState(() => _nightStart = val!),
                          ),
                          const Text("to"),
                          DropdownButton<int>(
                            value: _nightEnd,
                            dropdownColor: const Color(0xFF2A2A2A),
                            items: List.generate(24, (i) => DropdownMenuItem(value: i, child: Text(_formatHour(i)))),
                            onChanged: (val) => setState(() => _nightEnd = val!),
                          ),
                        ],
                      )
                    ]
                  ],
                ),
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
                  FocusScope.of(context).unfocus();
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

            // --- DOODLE MANAGEMENT ---
            Card(
              color: const Color(0xFF1E1E1E),
              child: ListTile(
                leading: const Icon(Icons.brush, color: Colors.blueAccent),
                title: const Text("Manage Doodles", style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text("Let your creativity shine!"),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  FocusScope.of(context).unfocus();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const DoodleGallery(),
                    ),
                  );
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
                    
                    // --- NEW LOCATION BUTTON ---
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent.withValues(alpha: 0.2),
                          foregroundColor: Colors.blueAccent,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _isFetchingLocation ? null : _getCurrentLocation,
                        icon: _isFetchingLocation 
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.my_location),
                        label: Text(
                          _isFetchingLocation ? "Fetching GPS..." : "Use Current Location",
                          style: const TextStyle(fontWeight: FontWeight.bold)
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(controller: _latCtrl, decoration: const InputDecoration(labelText: "Latitude", border: OutlineInputBorder()), keyboardType: TextInputType.number,onTapOutside: (event) => FocusScope.of(context).unfocus(),),
                    const SizedBox(height: 16),
                    TextField(controller: _lngCtrl, decoration: const InputDecoration(labelText: "Longitude", border: OutlineInputBorder()), keyboardType: TextInputType.number,onTapOutside: (event) => FocusScope.of(context).unfocus(),),
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
                    TextField(controller: _osUserCtrl, decoration: const InputDecoration(labelText: "Username", border: OutlineInputBorder()),onTapOutside: (event) => FocusScope.of(context).unfocus(),),
                    const SizedBox(height: 16),
                    TextField(controller: _osPassCtrl, decoration: const InputDecoration(labelText: "Password", border: OutlineInputBorder()), obscureText: true,onTapOutside: (event) => FocusScope.of(context).unfocus(),),
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
              onPressed: _isResetting ? null : _confirmFactoryReset,
              icon: _isResetting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator()) : const Icon(Icons.warning_amber_rounded),
              label: const Text("FACTORY RESET PANEL", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 32),
          ],
        ),
    );
  }
}