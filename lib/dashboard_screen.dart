import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'rgbop_mdns_service.dart';
import 'gif_manager_screen.dart';
import 'package:geolocator/geolocator.dart';
import 'doodle_gallery.dart';
import 'spotify_auth_callback_controller.dart';

enum RadarTimeFormat { off, format12h, format24h }

enum RadarUnitFormat { off, km, mi }

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final RGBopMdnsService _mdnsService = RGBopMdnsService();
  String? _panelIp;
  bool _isLoading = true;
  bool _connectionFailed = false;
  bool _isSaving = false;
  bool _isResetting = false;
  bool _isAuthorizingSpotify = false;

  // --- Settings State ---
  bool _showClock = true;
  bool _showGifs = true;
  bool _showDate = true;
  bool _showWeather = true;
  bool _showRadar = true;
  bool _showISS = true;
  bool _showPlanes = true;
  bool _showEarthquake = true;
  bool _showSpotify = true;
  bool _showDiags = true;
  bool _showTextBlast = true;
  bool _showDoodles = true;
  double _brightness = 128;
  bool _nightMode = false;
  int _nightStart = 22;
  int _nightEnd = 6;
  bool _isFetchingLocation = false;
  int _transitionTime = 10;
  RadarTimeFormat _radarTimeFormat = RadarTimeFormat.off;
  RadarUnitFormat _radarUnitFormat = RadarUnitFormat.off;
  int _radarZoomLevel = 7;

  final TextEditingController _latCtrl = TextEditingController();
  final TextEditingController _lngCtrl = TextEditingController();
  final TextEditingController _osUserCtrl = TextEditingController();
  final TextEditingController _osPassCtrl = TextEditingController();
  final TextEditingController _spotifyRefreshTokenCtrl =
      TextEditingController();
  late final VoidCallback _spotifyCallbackListener;
  String? _lastHandledSpotifyCallbackUri;

  String _formatHour(int h) {
    if (h == 0) return "12 AM";
    if (h == 12) return "12 PM";
    return h > 12 ? "${h - 12} PM" : "$h AM";
  }

  String _formatRadarTimeFormatLabel(RadarTimeFormat format) {
    return switch (format) {
      RadarTimeFormat.off => 'Off',
      RadarTimeFormat.format12h => '12 Hour',
      RadarTimeFormat.format24h => '24 Hour',
    };
  }

  String _formatRadarUnitFormatLabel(RadarUnitFormat format) {
    return switch (format) {
      RadarUnitFormat.off => 'Off',
      RadarUnitFormat.km => 'Kilometers',
      RadarUnitFormat.mi => 'Miles',
    };
  }

  String _formatRadarZoomLabel(int zoomLevel) {
    return switch (zoomLevel) {
      5 => '5 - ~160 miles (~260 km)',
      6 => '6 - ~80 miles (~130 km)',
      7 => '7 - ~40 miles (~65 km)',
      _ => '7 - ~40 miles (~65 km)',
    };
  }

  RadarTimeFormat _parseRadarTimeFormat(dynamic value) {
    final raw = value?.toString();
    return switch (raw) {
      'FORMAT_12H' => RadarTimeFormat.format12h,
      'FORMAT_24H' => RadarTimeFormat.format24h,
      _ => RadarTimeFormat.off,
    };
  }

  RadarUnitFormat _parseRadarUnitFormat(dynamic value) {
    final raw = value?.toString();
    return switch (raw) {
      'KM' => RadarUnitFormat.km,
      'MI' => RadarUnitFormat.mi,
      _ => RadarUnitFormat.off,
    };
  }

  String _serializeRadarTimeFormat(RadarTimeFormat format) {
    return switch (format) {
      RadarTimeFormat.off => 'OFF',
      RadarTimeFormat.format12h => 'FORMAT_12H',
      RadarTimeFormat.format24h => 'FORMAT_24H',
    };
  }

  String _serializeRadarUnitFormat(RadarUnitFormat format) {
    return switch (format) {
      RadarUnitFormat.off => 'OFF',
      RadarUnitFormat.km => 'KM',
      RadarUnitFormat.mi => 'MI',
    };
  }

  int _parseRadarZoomLevel(dynamic value) {
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed != null && parsed >= 5 && parsed <= 7) {
      return parsed;
    }
    return 7;
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
        throw Exception(
          "Location permissions are permanently denied. Please enable in settings.",
        );
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
          content: Text(
            e.toString(),
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isFetchingLocation = false);
      }
    }
  }

  bool _dashboardInitialized = false;

  @override
  void initState() {
    super.initState();
    _spotifyCallbackListener = _maybeHandleSpotifyAuthCallback;
    SpotifyAuthCallbackController.instance.latestCallback.addListener(
      _spotifyCallbackListener,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_dashboardInitialized) {
      _dashboardInitialized = true;
      _initDashboard();
    }
  }

  Future<void> _initDashboard() async {
    // 1. Use the IP passed from BootRouter if available, otherwise re-discover.
    final routeIp = ModalRoute.of(context)?.settings.arguments as String?;
    String? ip = routeIp;

    if (ip == null) {
      try {
        ip = await _mdnsService.findPanelIp().timeout(
          const Duration(seconds: 8),
        );
      } catch (_) {
        ip = null;
      }
    }

    if (ip == null) {
      if (mounted) {
        setState(() {
          _connectionFailed = true;
          _isLoading = false;
        });
      }
      return;
    }

    _panelIp = ip;
    _connectionFailed = false;
    await _fetchSettings();
  }

  Future<void> _fetchSettings() async {
    try {
      final response = await http.get(
        Uri.parse('http://$_panelIp/api/settings'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _showGifs = data['gifs'] ?? true;
          _showClock = data['clock'] ?? true;
          _showDate = data['date'] ?? true;
          _showWeather = data['weather'] ?? true;
          _showRadar = data['radar'] ?? true;
          _radarTimeFormat = _parseRadarTimeFormat(data['radarTimeFormat']);
          _radarUnitFormat = _parseRadarUnitFormat(data['radarUnitFormat']);
          _radarZoomLevel = _parseRadarZoomLevel(data['radarZoomLevel']);
          _showISS = data['iss'] ?? true;
          _showPlanes = data['planes'] ?? true;
          _showEarthquake = data['earthquake'] ?? true;
          _showSpotify = data['spotify'] ?? true;
          _showDiags = data['diags'] ?? true;
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
          _spotifyRefreshTokenCtrl.text = data['spotifyRefreshToken'] ?? '';
          _isLoading = false;
        });
        _maybeHandleSpotifyAuthCallback();
      } else {
        _showError("Failed to load panel settings: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Failed to load panel settings.");
    } finally {
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _saveSettings() async {
    await _saveSettingsInternal();
  }

  Future<bool> _saveSettingsInternal({
    String successMessage = "Settings saved to panel!",
  }) async {
    if (_panelIp == null) return false;

    setState(() => _isSaving = true);
    try {
      final body = jsonEncode({
        "gifs": _showGifs,
        "clock": _showClock,
        "date": _showDate,
        "weather": _showWeather,
        "radar": _showRadar,
        "radarTimeFormat": _serializeRadarTimeFormat(_radarTimeFormat),
        "radarUnitFormat": _serializeRadarUnitFormat(_radarUnitFormat),
        "radarZoomLevel": _radarZoomLevel,
        "iss": _showISS,
        "planes": _showPlanes,
        "earthquake": _showEarthquake,
        "spotify": _showSpotify,
        "diags": _showDiags,
        "textblast": _showTextBlast,
        "doodles": _showDoodles,
        "lat": double.tryParse(_latCtrl.text) ?? 34.16,
        "lng": double.tryParse(_lngCtrl.text) ?? -84.80,
        "osUser": _osUserCtrl.text,
        "osPass": _osPassCtrl.text,
        "spotifyClientId": "",
        "spotifyClientSecret": "",
        "spotifyRefreshToken": _spotifyRefreshTokenCtrl.text,
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
        if (successMessage.isNotEmpty) {
          _showSuccess(successMessage);
        }
        return true;
      }

      _showError("Save failed: ${response.statusCode}");
      return false;
    } catch (e) {
      _showError("Network error while saving.");
      return false;
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _maybeHandleSpotifyAuthCallback() {
    final callback =
        SpotifyAuthCallbackController.instance.latestCallback.value;
    if (callback == null || _panelIp == null || _isLoading) {
      return;
    }

    final callbackUri = callback.uri.toString();
    if (_lastHandledSpotifyCallbackUri == callbackUri) {
      return;
    }

    _lastHandledSpotifyCallbackUri = callbackUri;
    unawaited(_applySpotifyAuthCallback(callback));
  }

  Future<void> _applySpotifyAuthCallback(SpotifyAuthCallback callback) async {
    if (mounted) {
      setState(() {
        _spotifyRefreshTokenCtrl.text = callback.refreshToken;
        _isAuthorizingSpotify = false;
      });
    } else {
      _spotifyRefreshTokenCtrl.text = callback.refreshToken;
    }

    final saved = await _saveSettingsInternal(
      successMessage: 'Spotify connected and saved to panel.',
    );

    if (saved) {
      SpotifyAuthCallbackController.instance.clearLatestCallback(callback.uri);
    } else {
      _lastHandledSpotifyCallbackUri = null;
    }
  }

  Future<void> _launchSpotifyLogin() async {
    final loginUri = Uri.parse('https://rgbop.com/login');

    setState(() => _isAuthorizingSpotify = true);

    try {
      final launched = await launchUrl(
        loginUri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched) {
        if (mounted) {
          setState(() => _isAuthorizingSpotify = false);
        }
        _showError('Could not open Spotify login.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isAuthorizingSpotify = false);
      }
      _showError('Could not open Spotify login.');
    }
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
              onPressed: () =>
                  Navigator.of(context).pop(), // Just close the dialog
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text(
                "Yes, Reset Panel",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              onPressed: () {
                Navigator.of(context).pop(); // Close the dialog first
                _factoryResetPanel(); // Then execute the actual reset
              },
            ),
          ],
        );
      },
    );
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.green),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_connectionFailed || _panelIp == null) {
      return Scaffold(
        appBar: AppBar(
          leadingWidth: 86,
          leading: TextButton.icon(
            onPressed: () => Navigator.pushReplacementNamed(context, '/'),
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Exit'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.only(left: 8),
            ),
          ),
          title: const Text("RGBop Control"),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.wifi_off, color: Colors.redAccent, size: 64),
                const SizedBox(height: 16),
                const Text(
                  "Panel not reachable right now.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "Try reconnecting first. Use Bluetooth setup only for a new or reset panel.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                  ),
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                      _connectionFailed = false;
                    });
                    _initDashboard();
                  },
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  label: const Text(
                    "Retry Panel",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.blueAccent),
                  ),
                  onPressed: () =>
                      Navigator.pushReplacementNamed(context, '/setup'),
                  icon: const Icon(Icons.bluetooth, color: Colors.blueAccent),
                  label: const Text(
                    "Set Up New Panel",
                    style: TextStyle(color: Colors.blueAccent),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 86,
        leading: TextButton.icon(
          onPressed: () => Navigator.pushReplacementNamed(context, '/'),
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('Exit'),
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            padding: const EdgeInsets.only(left: 8),
          ),
        ),
        title: const Text("RGBop Control"),
        actions: [
          _isSaving
              ? const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.save, color: Colors.blueAccent),
                  onPressed: _saveSettings,
                ),
        ],
      ),

      // 1. ADD THE GESTURE DETECTOR HERE TO FIX THE KEYBOARD
      body: ListView(
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
                  title: Text(
                    "Active Widgets",
                    style: TextStyle(
                      color: Colors.blueAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  leading: Icon(Icons.dashboard, color: Colors.blueAccent),
                ),
                SwitchListTile(
                  title: const Text("Diagnostics"),
                  value: _showDiags,
                  onChanged: (v) => setState(() => _showDiags = v),
                ),
                SwitchListTile(
                  title: const Text("GIFs"),
                  value: _showGifs,
                  onChanged: (v) => setState(() => _showGifs = v),
                ),
                SwitchListTile(
                  title: const Text("Clocks"),
                  value: _showClock,
                  onChanged: (v) => setState(() => _showClock = v),
                ),
                SwitchListTile(
                  title: const Text("Date Progress"),
                  value: _showDate,
                  onChanged: (v) => setState(() => _showDate = v),
                ),
                SwitchListTile(
                  title: const Text("Weather"),
                  value: _showWeather,
                  onChanged: (v) => setState(() => _showWeather = v),
                ),
                SwitchListTile(
                  title: const Text("Radar"),
                  value: _showRadar,
                  onChanged: (v) => setState(() => _showRadar = v),
                ),
                if (_showRadar) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.0),
                    child: Divider(color: Colors.white24),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Radar Settings",
                          style: TextStyle(
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<RadarTimeFormat>(
                          initialValue: _radarTimeFormat,
                          decoration: const InputDecoration(
                            labelText: "Radar Time Format",
                            border: OutlineInputBorder(),
                          ),
                          dropdownColor: const Color(0xFF2A2A2A),
                          items: RadarTimeFormat.values
                              .map(
                                (format) => DropdownMenuItem(
                                  value: format,
                                  child: Text(
                                    _formatRadarTimeFormatLabel(format),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _radarTimeFormat = value);
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<RadarUnitFormat>(
                          initialValue: _radarUnitFormat,
                          decoration: const InputDecoration(
                            labelText: "Radar Unit Format",
                            border: OutlineInputBorder(),
                          ),
                          dropdownColor: const Color(0xFF2A2A2A),
                          items: RadarUnitFormat.values
                              .map(
                                (format) => DropdownMenuItem(
                                  value: format,
                                  child: Text(
                                    _formatRadarUnitFormatLabel(format),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _radarUnitFormat = value);
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
                          initialValue: _radarZoomLevel,
                          decoration: const InputDecoration(
                            labelText: "Radar Zoom Level",
                            border: OutlineInputBorder(),
                          ),
                          isExpanded: true,
                          dropdownColor: const Color(0xFF2A2A2A),
                          selectedItemBuilder: (context) {
                            return [5, 6, 7]
                                .map(
                                  (zoomLevel) => Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      _formatRadarZoomLabel(zoomLevel),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                )
                                .toList();
                          },
                          items: [5, 6, 7]
                              .map(
                                (zoomLevel) => DropdownMenuItem(
                                  value: zoomLevel,
                                  child: Text(
                                    _formatRadarZoomLabel(zoomLevel),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _radarZoomLevel = value);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ],
                SwitchListTile(
                  title: const Text("ISS Tracker"),
                  value: _showISS,
                  onChanged: (v) => setState(() => _showISS = v),
                ),
                SwitchListTile(
                  title: const Text("Planes"),
                  value: _showPlanes,
                  onChanged: (v) => setState(() => _showPlanes = v),
                ),
                SwitchListTile(
                  title: const Text("Earthquake"),
                  value: _showEarthquake,
                  onChanged: (v) => setState(() => _showEarthquake = v),
                ),
                SwitchListTile(
                  title: const Text("Spotify"),
                  value: _showSpotify,
                  onChanged: (v) => setState(() => _showSpotify = v),
                ),
                SwitchListTile(
                  title: const Text("Text Blast"),
                  value: _showTextBlast,
                  onChanged: (v) => setState(() => _showTextBlast = v),
                ),
                SwitchListTile(
                  title: const Text("Doodles"),
                  value: _showDoodles,
                  onChanged: (v) => setState(() => _showDoodles = v),
                ),

                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16.0),
                  child: Divider(color: Colors.white24),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 8.0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Widget Display Duration",
                        style: TextStyle(color: Colors.white70),
                      ),
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
                            width:
                                40, // Fixed width prevents jumping as numbers change
                            child: Text(
                              "${_transitionTime}s",
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.right,
                            ),
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
                      Text(
                        "Display & Brightness",
                        style: TextStyle(
                          color: Colors.amberAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
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
                          items: List.generate(
                            24,
                            (i) => DropdownMenuItem(
                              value: i,
                              child: Text(_formatHour(i)),
                            ),
                          ),
                          onChanged: (val) =>
                              setState(() => _nightStart = val!),
                        ),
                        const Text("to"),
                        DropdownButton<int>(
                          value: _nightEnd,
                          dropdownColor: const Color(0xFF2A2A2A),
                          items: List.generate(
                            24,
                            (i) => DropdownMenuItem(
                              value: i,
                              child: Text(_formatHour(i)),
                            ),
                          ),
                          onChanged: (val) => setState(() => _nightEnd = val!),
                        ),
                      ],
                    ),
                  ],
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
              title: const Text(
                "Manage GIFs",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: const Text("Upload and delete panel animations"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                FocusScope.of(context).unfocus();
                if (_panelIp != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          GifManagerScreen(panelIp: _panelIp!),
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
              title: const Text(
                "Manage Doodles",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: const Text("Let your creativity shine!"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                FocusScope.of(context).unfocus();
                if (_panelIp == null || _panelIp!.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'No panel selected. Return to picker and reconnect.',
                      ),
                    ),
                  );
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => DoodleGallery(panelIp: _panelIp),
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
                      Text(
                        "Location Settings",
                        style: TextStyle(
                          color: Colors.blueAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // --- NEW LOCATION BUTTON ---
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent.withValues(
                          alpha: 0.2,
                        ),
                        foregroundColor: Colors.blueAccent,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _isFetchingLocation
                          ? null
                          : _getCurrentLocation,
                      icon: _isFetchingLocation
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.my_location),
                      label: Text(
                        _isFetchingLocation
                            ? "Fetching GPS..."
                            : "Use Current Location",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _latCtrl,
                    decoration: const InputDecoration(
                      labelText: "Latitude",
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onTapOutside: (event) => FocusScope.of(context).unfocus(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _lngCtrl,
                    decoration: const InputDecoration(
                      labelText: "Longitude",
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onTapOutside: (event) => FocusScope.of(context).unfocus(),
                  ),
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
                      Text(
                        "OpenSky API",
                        style: TextStyle(
                          color: Colors.blueAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _osUserCtrl,
                    decoration: const InputDecoration(
                      labelText: "Username",
                      border: OutlineInputBorder(),
                    ),
                    onTapOutside: (event) => FocusScope.of(context).unfocus(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _osPassCtrl,
                    decoration: const InputDecoration(
                      labelText: "Password",
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                    onTapOutside: (event) => FocusScope.of(context).unfocus(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
          Card(
            color: const Color(0xFF1E1E1E),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  const Row(
                    children: [
                      Icon(Icons.music_note, color: Colors.greenAccent),
                      SizedBox(width: 16),
                      Text(
                        "Spotify API",
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _spotifyRefreshTokenCtrl.text.isEmpty
                        ? "Connect Spotify in your browser to send a refresh token back to this app and save it to the panel."
                        : "Spotify is connected for this panel. Reconnect if you want to replace the saved refresh token.",
                    style: const TextStyle(color: Colors.white70, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141414),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _spotifyRefreshTokenCtrl.text.isEmpty
                              ? Icons.link_off
                              : Icons.check_circle,
                          color: _spotifyRefreshTokenCtrl.text.isEmpty
                              ? Colors.white54
                              : Colors.greenAccent,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _spotifyRefreshTokenCtrl.text.isEmpty
                                ? "No Spotify refresh token saved"
                                : "Refresh token saved to this panel",
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.greenAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: (_isAuthorizingSpotify || _isSaving)
                          ? null
                          : _launchSpotifyLogin,
                      icon: _isAuthorizingSpotify
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              _spotifyRefreshTokenCtrl.text.isEmpty
                                  ? Icons.open_in_browser
                                  : Icons.sync,
                            ),
                      label: Text(
                        _isAuthorizingSpotify
                            ? "Waiting For Spotify..."
                            : _spotifyRefreshTokenCtrl.text.isEmpty
                            ? "Connect Spotify"
                            : "Reconnect Spotify",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
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
            icon: _isResetting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(),
                  )
                : const Icon(Icons.warning_amber_rounded),
            label: const Text(
              "FACTORY RESET PANEL",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  @override
  void dispose() {
    SpotifyAuthCallbackController.instance.latestCallback.removeListener(
      _spotifyCallbackListener,
    );
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _osUserCtrl.dispose();
    _osPassCtrl.dispose();
    _spotifyRefreshTokenCtrl.dispose();
    super.dispose();
  }
}
