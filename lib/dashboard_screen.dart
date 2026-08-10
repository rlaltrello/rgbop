import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'dart:convert';
import 'rgbop_mdns_service.dart';
import 'gif_manager_screen.dart';
import 'game_controller_screen.dart';
import 'package:geolocator/geolocator.dart';
import 'doodle_gallery.dart';
import 'spotify_auth_callback_controller.dart';
import 'app_palette.dart';
import 'demo/demo_mode_controller.dart';

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
  String _panelName = 'RGBop Panel';
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
  bool _weatherUnitFahrenheit = true;
  bool _showRadar = true;
  bool _showISS = true;
  bool _showPlanes = true;
  bool _showEarthquake = true;
  bool _showSpotify = true;
  bool _spotifyShowOnPause = true;
  bool _spotifyShowOnlyAlbumArt = false;
  bool _showDiags = true;
  bool _showTextBlast = true;
  int _textBlastTextScale = 1;
  bool _textBlastTextCustomMessage = false;
  late final TextEditingController _textBlastCtrl;
  int _textBlastTextColor = 0x00FFFF00;
  int _textBlastBackgroundColor = 0x00000000;
  int _textBlastCycles = 1;
  double _textBlastSpeed = 40.0;
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

  bool get _isDemoMode => DemoModeController.instance.isDemoIp(_panelIp);

  String _formatHour(int h) {
    if (h == 0) return "12 AM";
    if (h == 12) return "12 PM";
    return h > 12 ? "${h - 12} PM" : "$h AM";
  }

  String _formatWeatherUnitFormatLabel(bool isFahrenheit) {
    return isFahrenheit ? 'Fahrenheit (°F)' : 'Celsius (°C)';
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

  Future<void> _showPanelNameEditor() async {
    final ctrl = TextEditingController(text: _panelName);

    final newName = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppPalette.surfacePanel,
          title: const Text(
            'Panel Name',
            style: TextStyle(color: Colors.white),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (!mounted ||
        newName == null ||
        newName.isEmpty ||
        newName == _panelName) {
      return;
    }

    final previous = _panelName;
    setState(() => _panelName = newName);

    final saved = await _saveSettingsInternal(
      successMessage: 'Panel name saved.',
    );
    if (!saved && mounted) {
      setState(() => _panelName = previous);
    }
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

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      setState(() {
        _latCtrl.text = position.latitude.toStringAsFixed(4);
        _lngCtrl.text = position.longitude.toStringAsFixed(4);
      });
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString(),
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: AppPalette.statusDanger,
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
    _textBlastCtrl = TextEditingController();
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

  void _exitDemoMode() {
    DemoModeController.instance.disable();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/');
  }

  Future<void> _fetchSettings() async {
    if (_isDemoMode) {
      final data = DemoModeController.instance.settings;
      setState(() {
        _panelName = (data['panelName'] ?? data['name'] ?? _panelName)
            .toString()
            .trim();
        if (_panelName.isEmpty) {
          _panelName = 'Demo Panel';
        }
        _showGifs = data['gifs'] ?? true;
        _showClock = data['clock'] ?? true;
        _showDate = data['date'] ?? true;
        _showWeather = data['weather'] ?? true;
        _weatherUnitFahrenheit = data['weatherUnitFahrenheit'] ?? true;
        _showRadar = data['radar'] ?? true;
        _radarTimeFormat = _parseRadarTimeFormat(data['radarTimeFormat']);
        _radarUnitFormat = _parseRadarUnitFormat(data['radarUnitFormat']);
        _radarZoomLevel = _parseRadarZoomLevel(data['radarZoomLevel']);
        _showISS = data['iss'] ?? true;
        _showPlanes = data['planes'] ?? true;
        _showEarthquake = data['earthquake'] ?? true;
        _showSpotify = data['spotify'] ?? true;
        _spotifyShowOnPause = data['spotifyShowOnPause'] ?? true;
        _spotifyShowOnlyAlbumArt = data['spotifyShowOnlyAlbumArt'] ?? false;
        _showDiags = data['diags'] ?? true;
        _showTextBlast = data['textblast'] ?? true;
        _textBlastTextScale = data['textBlastTextScale'] ?? 1;
        _textBlastCtrl.text = data['textBlastText'] ?? '';
        _textBlastTextColor = data['textBlastTextColor'] ?? 0x00FFFF00;
        _textBlastBackgroundColor =
            data['textBlastBackgroundColor'] ?? 0x00000000;
        _textBlastTextCustomMessage =
            data['textBlastTextCustomMessage'] ?? false;
        _textBlastCycles = data['textBlastCycles'] ?? 1;
        _textBlastSpeed = (data['textBlastSpeed'] ?? 40.0).toDouble();
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
      return;
    }

    try {
      final response = await http.get(
        Uri.parse('http://$_panelIp/api/settings'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _panelName = (data['panelName'] ?? data['name'] ?? _panelName)
              .toString()
              .trim();
          if (_panelName.isEmpty) {
            _panelName = 'RGBop Panel';
          }
          _showGifs = data['gifs'] ?? true;
          _showClock = data['clock'] ?? true;
          _showDate = data['date'] ?? true;
          _showWeather = data['weather'] ?? true;
          _weatherUnitFahrenheit = data['weatherUnitFahrenheit'] ?? true;
          _showRadar = data['radar'] ?? true;
          _radarTimeFormat = _parseRadarTimeFormat(data['radarTimeFormat']);
          _radarUnitFormat = _parseRadarUnitFormat(data['radarUnitFormat']);
          _radarZoomLevel = _parseRadarZoomLevel(data['radarZoomLevel']);
          _showISS = data['iss'] ?? true;
          _showPlanes = data['planes'] ?? true;
          _showEarthquake = data['earthquake'] ?? true;
          _showSpotify = data['spotify'] ?? true;
          _spotifyShowOnPause = data['spotifyShowOnPause'] ?? true;
          _spotifyShowOnlyAlbumArt = data['spotifyShowOnlyAlbumArt'] ?? false;
          _showDiags = data['diags'] ?? true;
          _showTextBlast = data['textblast'] ?? true;
          _textBlastTextScale = data['textBlastTextScale'] ?? 1;
          _textBlastCtrl.text = data['textBlastText'] ?? '';
          _textBlastTextColor = data['textBlastTextColor'] ?? 0x00FFFF00;
          _textBlastBackgroundColor =
              data['textBlastBackgroundColor'] ?? 0x00000000;
          _textBlastTextCustomMessage =
              data['textBlastTextCustomMessage'] ?? false;
          _textBlastCycles = data['textBlastCycles'] ?? 1;
          _textBlastSpeed = (data['textBlastSpeed'] ?? 40.0).toDouble();
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
      final payload = {
        "panelName": _panelName,
        "gifs": _showGifs,
        "clock": _showClock,
        "date": _showDate,
        "weather": _showWeather,
        "weatherUnitFahrenheit": _weatherUnitFahrenheit,
        "radar": _showRadar,
        "radarTimeFormat": _serializeRadarTimeFormat(_radarTimeFormat),
        "radarUnitFormat": _serializeRadarUnitFormat(_radarUnitFormat),
        "radarZoomLevel": _radarZoomLevel,
        "iss": _showISS,
        "planes": _showPlanes,
        "earthquake": _showEarthquake,
        "spotify": _showSpotify,
        "spotifyShowOnPause": _spotifyShowOnPause,
        "spotifyShowOnlyAlbumArt": _spotifyShowOnlyAlbumArt,
        "diags": _showDiags,
        "textblast": _showTextBlast,
        "textBlastTextScale": _textBlastTextScale,
        "textBlastText": _textBlastCtrl.text,
        "textBlastTextColor": _textBlastTextColor,
        "textBlastBackgroundColor": _textBlastBackgroundColor,
        "textBlastTextCustomMessage": _textBlastTextCustomMessage,
        "textBlastCycles": _textBlastCycles,
        "textBlastSpeed": _textBlastSpeed,
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
      };

      if (_isDemoMode) {
        DemoModeController.instance.saveSettings(payload);
        if (successMessage.isNotEmpty) {
          _showSuccess(successMessage);
        }
        return true;
      }

      final body = jsonEncode(payload);

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

    if (_isDemoMode) {
      DemoModeController.instance.resetPanel();
      await _fetchSettings();
      if (mounted) {
        _showSuccess('Demo panel reset.');
        setState(() => _isResetting = false);
      }
      return;
    }

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

  void _showDashboardInstructions() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppPalette.surfacePanel,
          title: const Row(
            children: [
              Icon(Icons.info_outline, color: AppPalette.brandAccent),
              SizedBox(width: 8),
              Text(
                'Dashboard Guide',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
          content: const SingleChildScrollView(
            child: Text(
              'Welcome to your RGBop Control Dashboard!\n\n'
              '• Active Widgets: Toggle which items rotate on your LED panel display.\n'
              '• Location Settings: Used for local weather forecasts and radar map generation.\n'
              '• Spotify Integration: Connect your account to display live track info and album art directly on the panel.\n'
              '• Saving Changes: Be sure to tap the Save icon (floppy disk) on the top right whenever you modify settings to send them directly to your panel.',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppPalette.brandAccent,
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Got It',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmFactoryReset() async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppPalette.surfacePanel,
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppPalette.statusDanger),
              SizedBox(width: 8),
              Text(
                "Factory Reset?",
                style: TextStyle(color: AppPalette.statusDanger),
              ),
            ],
          ),
          content: const Text(
            "This will erase all Wi-Fi settings and preferences on the panel, forcing it back into Bluetooth setup mode. Are you absolutely sure?",
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: AppPalette.statusDanger,
              ),
              child: const Text(
                "Yes, Reset Panel",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              onPressed: () {
                Navigator.of(context).pop();
                _factoryResetPanel();
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
        SnackBar(
          content: Text(message),
          backgroundColor: AppPalette.statusDanger,
        ),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppPalette.statusSuccess,
        ),
      );
    }
  }

  void _openColorPickerDialog(
    BuildContext context, {
    required String title,
    required Color initialColor,
    required ValueChanged<Color> onColorSelected,
  }) {
    Color pickedColor = initialColor;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: BlockPicker(
              pickerColor: initialColor,
              onColorChanged: (color) => pickedColor = color,
            ),
          ),
          actions: [
            TextButton(
              child: const Text("Cancel"),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text("Select"),
              onPressed: () {
                onColorSelected(pickedColor);
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildDashboardNavTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      color: AppPalette.surfacePanel,
      elevation: 3,
      shadowColor: AppPalette.overlayScrim,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppPalette.overlayWhite12),
      ),
      child: ListTile(
        minTileHeight: 90,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppPalette.brandAccent.withValues(alpha: 0.2),
            shape: BoxShape.circle,
            border: Border.all(color: AppPalette.overlayWhite12),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: AppPalette.brandAccent),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            subtitle,
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.82),
            ),
          ),
        ),
        trailing: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppPalette.brandAccent.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.chevron_right, color: AppPalette.brandAccent),
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _buildDashboardSectionHeader({
    required String title,
    required IconData icon,
  }) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppPalette.brandAccent.withValues(alpha: 0.2),
            shape: BoxShape.circle,
            border: Border.all(color: AppPalette.overlayWhite12),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: AppPalette.brandAccent, size: 20),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: const TextStyle(
            color: AppPalette.brandAccent,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      ],
    );
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
                const Icon(
                  Icons.wifi_off,
                  color: AppPalette.statusDanger,
                  size: 64,
                ),
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
                    backgroundColor: AppPalette.brandAccent,
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
                    side: const BorderSide(color: AppPalette.brandAccent),
                  ),
                  onPressed: () =>
                      Navigator.pushReplacementNamed(context, '/setup'),
                  icon: const Icon(
                    Icons.bluetooth,
                    color: AppPalette.brandAccent,
                  ),
                  label: const Text(
                    "Set Up New Panel",
                    style: TextStyle(color: AppPalette.brandAccent),
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
        title: Text(_isDemoMode ? "RGBop Control (Demo)" : "RGBop Control"),
        actions: [
          if (_isDemoMode)
            TextButton.icon(
              onPressed: _exitDemoMode,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Exit Demo'),
              style: TextButton.styleFrom(
                foregroundColor: AppPalette.statusWarning,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.help_outline, color: AppPalette.brandAccent),
            tooltip: 'Dashboard Help',
            onPressed: _showDashboardInstructions,
          ),
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
                  icon: const Icon(Icons.save, color: AppPalette.brandAccent),
                  onPressed: _saveSettings,
                ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- PANEL IP HEADER ---
          Padding(
            padding: const EdgeInsets.only(bottom: 16.0, top: 8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                InkWell(
                  onTap: _showPanelNameEditor,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _panelName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.edit, color: Colors.white54, size: 16),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
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
              ],
            ),
          ),

          if (_isDemoMode)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppPalette.brandAccent.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppPalette.brandAccent),
              ),
              child: const Row(
                children: [
                  Icon(Icons.science, color: AppPalette.brandAccent),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Demo Mode active: no hardware required. Changes are simulated locally for App Review.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),

          // --- WIDGET TOGGLES ---
          Card(
            color: AppPalette.surfacePanel,
            child: Column(
              children: [
                const ListTile(
                  title: Text(
                    "Active Widgets",
                    style: TextStyle(
                      color: AppPalette.brandAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  leading: Icon(Icons.dashboard, color: AppPalette.brandAccent),
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
                if (_showWeather)
                    Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      initiallyExpanded: false,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16.0),
                      backgroundColor: Colors.black.withValues(alpha: 0.2),
                      title: const Padding(
                        padding: EdgeInsets.only(left: 12.0),
                        child: Text(
                          "Weather Settings",
                          style: TextStyle(
                            color: AppPalette.brandAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [

                              const SizedBox(height: 12),
                              DropdownButtonFormField<bool>(
                                initialValue: _weatherUnitFahrenheit,
                                decoration: const InputDecoration(
                                  labelText: "Weather Unit",
                                  border: OutlineInputBorder(),
                                ),
                                dropdownColor: const Color(0xFF2A2A2A),
                                items: [true, false]
                                    .map(
                                      (isFahrenheit) => DropdownMenuItem(
                                        value: isFahrenheit,
                                        child: Text(
                                          _formatWeatherUnitFormatLabel(isFahrenheit),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => _weatherUnitFahrenheit = value);
                                  }
                                },
                              ),
                              const SizedBox(height: 12),
                              
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                SwitchListTile(
                  title: const Text("Radar"),
                  value: _showRadar,
                  onChanged: (v) => setState(() => _showRadar = v),
                ),
                if (_showRadar)
                  Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      initiallyExpanded: false,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16.0),
                      backgroundColor: Colors.black.withValues(alpha: 0.2),
                      title: const Padding(
                        padding: EdgeInsets.only(left: 12.0),
                        child: Text(
                          "Radar Settings",
                          style: TextStyle(
                            color: AppPalette.brandAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
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
                    ),
                  ),
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
                if (_showSpotify)
                  Theme(
                    data: Theme.of(context).copyWith(
                      dividerColor: const Color.fromARGB(0, 111, 49, 49),
                    ),
                    child: ExpansionTile(
                      initiallyExpanded: false,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16.0),
                      backgroundColor: Colors.black.withValues(alpha: 0.2),
                      collapsedBackgroundColor: Colors.transparent,
                      title: const Padding(
                        padding: EdgeInsets.only(left: 12.0),
                        child: Text(
                          "Spotify Settings",
                          style: TextStyle(
                            color: AppPalette.brandAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Theme(
                                data: Theme.of(context).copyWith(
                                  switchTheme: SwitchThemeData(
                                    thumbColor:
                                        WidgetStateProperty.resolveWith<Color>((
                                          states,
                                        ) {
                                          if (states.contains(
                                            WidgetState.selected,
                                          )) {
                                            return AppPalette.brandAccent;
                                          }
                                          return Colors.grey;
                                        }),
                                    trackColor:
                                        WidgetStateProperty.resolveWith<Color>((
                                          states,
                                        ) {
                                          if (states.contains(
                                            WidgetState.selected,
                                          )) {
                                            return AppPalette.brandAccent
                                                .withValues(alpha: 0.5);
                                          }
                                          return Colors.grey.withValues(
                                            alpha: 0.3,
                                          );
                                        }),
                                  ),
                                ),
                                child: SwitchListTile(
                                  title: const Text("Show Spotify on Pause"),
                                  value: _spotifyShowOnPause,
                                  onChanged: (v) =>
                                      setState(() => _spotifyShowOnPause = v),
                                ),
                              ),
                              Theme(
                                data: Theme.of(context).copyWith(
                                  switchTheme: SwitchThemeData(
                                    thumbColor:
                                        WidgetStateProperty.resolveWith<Color>((
                                          states,
                                        ) {
                                          if (states.contains(
                                            WidgetState.selected,
                                          )) {
                                            return AppPalette.brandAccent;
                                          }
                                          return Colors.grey;
                                        }),
                                    trackColor:
                                        WidgetStateProperty.resolveWith<Color>((
                                          states,
                                        ) {
                                          if (states.contains(
                                            WidgetState.selected,
                                          )) {
                                            return AppPalette.brandAccent
                                                .withValues(alpha: 0.5);
                                          }
                                          return Colors.grey.withValues(
                                            alpha: 0.3,
                                          );
                                        }),
                                  ),
                                ),
                                child: SwitchListTile(
                                  title: const Text("Show Only Album Art"),
                                  value: _spotifyShowOnlyAlbumArt,
                                  onChanged: (v) => setState(
                                    () => _spotifyShowOnlyAlbumArt = v,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                SwitchListTile(
                  title: const Text("Text Blast"),
                  value: _showTextBlast,
                  onChanged: (v) => setState(() => _showTextBlast = v),
                ),
                if (_showTextBlast)
                  Theme(
                    data: Theme.of(context).copyWith(
                      dividerColor: const Color.fromARGB(0, 111, 49, 49),
                    ),
                    child: ExpansionTile(
                      initiallyExpanded: false,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16.0),
                      backgroundColor: Colors.black.withValues(alpha: 0.2),
                      collapsedBackgroundColor: Colors.transparent,
                      title: const Padding(
                        padding: EdgeInsets.only(left: 12.0),
                        child: Text(
                          "Text Blast Settings",
                          style: TextStyle(
                            color: AppPalette.brandAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Theme(
                                data: Theme.of(context).copyWith(
                                  switchTheme: SwitchThemeData(
                                    thumbColor:
                                        WidgetStateProperty.resolveWith<Color>((
                                          states,
                                        ) {
                                          if (states.contains(
                                            WidgetState.selected,
                                          )) {
                                            return AppPalette.brandAccent;
                                          }
                                          return Colors.grey;
                                        }),
                                    trackColor:
                                        WidgetStateProperty.resolveWith<Color>((
                                          states,
                                        ) {
                                          if (states.contains(
                                            WidgetState.selected,
                                          )) {
                                            return AppPalette.brandAccent
                                                .withValues(alpha: 0.5);
                                          }
                                          return Colors.grey.withValues(
                                            alpha: 0.3,
                                          );
                                        }),
                                  ),
                                ),
                                child: SwitchListTile(
                                  title: const Text("Custom Message"),
                                  value: _textBlastTextCustomMessage,
                                  onChanged: (v) => setState(
                                    () => _textBlastTextCustomMessage = v,
                                  ),
                                ),
                              ),

                              if (_textBlastTextCustomMessage) ...[
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _textBlastCtrl,
                                  decoration: const InputDecoration(
                                    labelText: "Custom Text",
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onTapOutside: (_) =>
                                      FocusScope.of(context).unfocus(),
                                ),
                              ],

                              const SizedBox(height: 16),

                              Row(
                                children: [
                                  const SizedBox(
                                    width: 100,
                                    child: Text("Text Scale:"),
                                  ),
                                  Expanded(
                                    child: Slider(
                                      value: _textBlastTextScale.toDouble(),
                                      min: 1,
                                      max: 5,
                                      divisions: 4,
                                      label: "$_textBlastTextScale",
                                      onChanged: (v) => setState(
                                        () => _textBlastTextScale = v.toInt(),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 30,
                                    child: Text(
                                      "$_textBlastTextScale",
                                      textAlign: TextAlign.end,
                                    ),
                                  ),
                                ],
                              ),

                              Row(
                                children: [
                                  const SizedBox(
                                    width: 100,
                                    child: Text("Cycles:"),
                                  ),
                                  Expanded(
                                    child: Slider(
                                      value: _textBlastCycles.toDouble(),
                                      min: 1,
                                      max: 5,
                                      divisions: 4,
                                      label: "$_textBlastCycles",
                                      onChanged: (v) => setState(
                                        () => _textBlastCycles = v.toInt(),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 30,
                                    child: Text(
                                      "$_textBlastCycles",
                                      textAlign: TextAlign.end,
                                    ),
                                  ),
                                ],
                              ),

                              Row(
                                children: [
                                  const SizedBox(
                                    width: 100,
                                    child: Text("Speed:"),
                                  ),
                                  Expanded(
                                    child: Slider(
                                      value: _textBlastSpeed,
                                      min: 10.0,
                                      max: 100.0,
                                      divisions: 18,
                                      label: _textBlastSpeed.toStringAsFixed(0),
                                      onChanged: (v) =>
                                          setState(() => _textBlastSpeed = v),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 30,
                                    child: Text(
                                      _textBlastSpeed.toStringAsFixed(0),
                                      textAlign: TextAlign.end,
                                    ),
                                  ),
                                ],
                              ),

                              const Divider(color: Colors.white24),

                              ListTile(
                                title: const Text("Text Color"),
                                trailing: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: Color(
                                      _textBlastTextColor | 0xFF000000,
                                    ),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white30,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                onTap: () => _openColorPickerDialog(
                                  context,
                                  title: "Pick Text Color",
                                  initialColor: Color(
                                    _textBlastTextColor | 0xFF000000,
                                  ),
                                  onColorSelected: (color) {
                                    setState(() {
                                      _textBlastTextColor =
                                          color.toARGB32() & 0x00FFFFFF;
                                    });
                                  },
                                ),
                              ),

                              ListTile(
                                title: const Text("Background Color"),
                                trailing: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: Color(
                                      _textBlastBackgroundColor | 0xFF000000,
                                    ),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white30,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                onTap: () => _openColorPickerDialog(
                                  context,
                                  title: "Pick Background Color",
                                  initialColor: Color(
                                    _textBlastBackgroundColor | 0xFF000000,
                                  ),
                                  onColorSelected: (color) {
                                    setState(() {
                                      _textBlastBackgroundColor =
                                          color.toARGB32() & 0x00FFFFFF;
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
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
                              activeColor: AppPalette.brandAccent,
                              label: "$_transitionTime sec",
                              onChanged: (val) {
                                setState(() => _transitionTime = val.toInt());
                              },
                            ),
                          ),
                          SizedBox(
                            width: 40,
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
            color: AppPalette.surfacePanel,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDashboardSectionHeader(
                    title: 'Display & Brightness',
                    icon: Icons.lightbulb_outline,
                  ),
                  const SizedBox(height: 16),
                  const Text("Global Brightness"),
                  Slider(
                    value: _brightness,
                    min: 1,
                    max: 255,
                    divisions: 254,
                    activeColor: AppPalette.brandAccent,
                    label: _brightness.round().toString(),
                    onChanged: (val) {
                      setState(() => _brightness = val);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Night Mode (Dim to Near Zero)"),
                    activeThumbColor: AppPalette.brandAccent,
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
          _buildDashboardNavTile(
            context: context,
            icon: Icons.gif_box,
            title: "Manage GIFs",
            subtitle: "Upload and delete panel animations",
            onTap: () {
              FocusScope.of(context).unfocus();
              if (_isDemoMode) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const GifManagerScreen(offlineMode: true),
                  ),
                );
              } else if (_panelIp != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => GifManagerScreen(panelIp: _panelIp!),
                  ),
                );
              }
            },
          ),
          const SizedBox(height: 16),

          // --- DOODLE MANAGEMENT ---
          _buildDashboardNavTile(
            context: context,
            icon: Icons.brush,
            title: "Manage Doodles",
            subtitle: "Let your creativity shine!",
            onTap: () {
              FocusScope.of(context).unfocus();
              if (_isDemoMode) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const DoodleGallery(offlineMode: true),
                  ),
                );
                return;
              }
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
          const SizedBox(height: 16),

          // --- GAME MODE ---
          _buildDashboardNavTile(
            context: context,
            icon: Icons.sports_esports,
            title: "Game Mode",
            subtitle: "Directional controls and fire button",
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
                  builder: (context) =>
                      GameControllerScreen(panelIp: _panelIp!),
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // --- LOCATION ---
          Card(
            color: AppPalette.surfacePanel,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  _buildDashboardSectionHeader(
                    title: 'Location Settings',
                    icon: Icons.location_on,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppPalette.brandAccent,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppPalette.surfaceTile,
                        disabledForegroundColor: Colors.white70,
                        side: const BorderSide(
                          color: Colors.white70,
                          width: 1.25,
                        ),
                        elevation: 4,
                        shadowColor: AppPalette.brandAccent,
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
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.2,
                        ),
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
            color: AppPalette.surfacePanel,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildDashboardSectionHeader(
                        title: 'OpenSky API',
                        icon: Icons.flight,
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final Uri url = Uri.parse(
                            'https://openskynetwork.github.io/opensky-api/rest.html#authentication',
                          );

                          final messenger = ScaffoldMessenger.of(context);
                          final launched = await launchUrl(
                            url,
                            mode: LaunchMode.externalApplication,
                          );

                          if (!launched) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('Cannot Launch URL.'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(
                          Icons.open_in_new,
                          size: 16,
                          color: Colors.grey,
                        ),
                        label: const Text(
                          "Get Credentials",
                          style: TextStyle(color: Colors.grey, fontSize: 12),
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
            color: AppPalette.surfacePanel,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  _buildDashboardSectionHeader(
                    title: 'Spotify API',
                    icon: Icons.music_note,
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
                              : AppPalette.brandAccent,
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
                        backgroundColor: AppPalette.brandAccent,
                        foregroundColor: Colors.white,
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
              backgroundColor: AppPalette.statusDanger.withValues(alpha: 0.2),
              foregroundColor: AppPalette.statusDanger,
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
    _textBlastCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _osUserCtrl.dispose();
    _osPassCtrl.dispose();
    _spotifyRefreshTokenCtrl.dispose();
    super.dispose();
  }
}
