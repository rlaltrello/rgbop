import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

class DemoModeController extends ChangeNotifier {
  DemoModeController._();

  static final DemoModeController instance = DemoModeController._();

  static const String demoHostToken = 'demo';
  static const String demoPanelIp = 'demo.local';

  bool _enabled = false;
  int _cursorX = 32;
  int _cursorY = 32;
  int _lastSeq = 0;
  int _lastButtons = 0;

  Map<String, dynamic> _settings = _defaultSettings();
  final List<Color> _matrix = List<Color>.filled(64 * 64, Colors.black);
  final Map<String, Uint8List> _localGifs = <String, Uint8List>{};
  final Map<String, DemoRemoteGif> _remoteGifs = <String, DemoRemoteGif>{};
  final Map<String, Uint8List> _localDoodles = <String, Uint8List>{};
  final Map<String, Uint8List> _remoteDoodles = <String, Uint8List>{};

  bool get isEnabled => _enabled;
  int get lastSeq => _lastSeq;
  int get lastButtons => _lastButtons;

  List<Color> get matrix => List<Color>.unmodifiable(_matrix);
  Map<String, dynamic> get settings => Map<String, dynamic>.from(_settings);

  Map<String, Uint8List> get localGifs => _copyByteMap(_localGifs);
  Map<String, DemoRemoteGif> get remoteGifs {
    final copy = <String, DemoRemoteGif>{};
    for (final entry in _remoteGifs.entries) {
      copy[entry.key] = DemoRemoteGif(
        bytes: Uint8List.fromList(entry.value.bytes),
        enabled: entry.value.enabled,
      );
    }
    return copy;
  }
  Map<String, Uint8List> get localDoodles => _copyByteMap(_localDoodles);
  Map<String, Uint8List> get remoteDoodles => _copyByteMap(_remoteDoodles);

  bool isDemoIp(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == demoHostToken || normalized == demoPanelIp;
  }

  void enable() {
    _enabled = true;
    notifyListeners();
  }

  void disable() {
    _enabled = false;
    notifyListeners();
  }

  void resetPanel() {
    _settings = _defaultSettings();
    for (var i = 0; i < _matrix.length; i++) {
      _matrix[i] = Colors.black;
    }
    _cursorX = 32;
    _cursorY = 32;
    _lastSeq = 0;
    _lastButtons = 0;
    _localGifs.clear();
    _remoteGifs.clear();
    _localDoodles.clear();
    _remoteDoodles.clear();
    notifyListeners();
  }

  void saveSettings(Map<String, dynamic> payload) {
    _settings = {
      ..._settings,
      ...payload,
    };
    notifyListeners();
  }

  void saveLocalGif(String filename, Uint8List bytes) {
    final key = _normalizeName(filename);
    if (key.isEmpty) return;
    _localGifs[key] = Uint8List.fromList(bytes);
    notifyListeners();
  }

  bool deleteLocalGif(String filename) {
    final key = _normalizeName(filename);
    if (key.isEmpty) return false;
    final removed = _localGifs.remove(key) != null;
    if (removed) notifyListeners();
    return removed;
  }

  bool importRemoteGifToLocal(String filename) {
    final key = _normalizeName(filename);
    if (key.isEmpty) return false;
    final remote = _remoteGifs[key];
    if (remote == null) return false;
    _localGifs[key] = Uint8List.fromList(remote.bytes);
    notifyListeners();
    return true;
  }

  bool toggleRemoteGif(String filename, bool enabled) {
    final key = _normalizeName(filename);
    if (key.isEmpty) return false;
    final remote = _remoteGifs[key];
    if (remote == null) return false;
    remote.enabled = enabled;
    notifyListeners();
    return true;
  }

  void syncLocalGifsToRemote() {
    _remoteGifs
      ..clear()
      ..addEntries(
        _localGifs.entries.map(
          (e) => MapEntry(
            e.key,
            DemoRemoteGif(bytes: Uint8List.fromList(e.value), enabled: true),
          ),
        ),
      );
    notifyListeners();
  }

  Uint8List? getLocalGifBytes(String filename) {
    final key = _normalizeName(filename);
    final data = _localGifs[key];
    return data == null ? null : Uint8List.fromList(data);
  }

  Uint8List? getRemoteGifBytes(String filename) {
    final key = _normalizeName(filename);
    final remote = _remoteGifs[key];
    return remote == null ? null : Uint8List.fromList(remote.bytes);
  }

  bool isRemoteGifEnabled(String filename) {
    final key = _normalizeName(filename);
    final remote = _remoteGifs[key];
    return remote?.enabled ?? true;
  }

  void saveLocalDoodle(String filename, Uint8List bytes) {
    final key = _normalizeName(filename);
    if (key.isEmpty) return;
    _localDoodles[key] = Uint8List.fromList(bytes);
    notifyListeners();
  }

  bool deleteLocalDoodle(String filename) {
    final key = _normalizeName(filename);
    if (key.isEmpty) return false;
    final removed = _localDoodles.remove(key) != null;
    if (removed) notifyListeners();
    return removed;
  }

  bool importRemoteDoodleToLocal(String filename) {
    final key = _normalizeName(filename);
    if (key.isEmpty) return false;
    final remote = _remoteDoodles[key];
    if (remote == null) return false;
    _localDoodles[key] = Uint8List.fromList(remote);
    notifyListeners();
    return true;
  }

  void syncLocalDoodlesToRemote() {
    _remoteDoodles
      ..clear()
      ..addEntries(
        _localDoodles.entries.map(
          (e) => MapEntry(e.key, Uint8List.fromList(e.value)),
        ),
      );
    notifyListeners();
  }

  bool deleteRemoteDoodle(String filename) {
    final key = _normalizeName(filename);
    if (key.isEmpty) return false;
    final removed = _remoteDoodles.remove(key) != null;
    if (removed) notifyListeners();
    return removed;
  }

  Uint8List? getLocalDoodleBytes(String filename) {
    final key = _normalizeName(filename);
    final data = _localDoodles[key];
    return data == null ? null : Uint8List.fromList(data);
  }

  Uint8List? getRemoteDoodleBytes(String filename) {
    final key = _normalizeName(filename);
    final data = _remoteDoodles[key];
    return data == null ? null : Uint8List.fromList(data);
  }

  Map<String, Uint8List> _copyByteMap(Map<String, Uint8List> source) {
    final copy = <String, Uint8List>{};
    for (final entry in source.entries) {
      copy[entry.key] = Uint8List.fromList(entry.value);
    }
    return copy;
  }

  String _normalizeName(String filename) {
    final normalized = filename.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) return '';
    if (!normalized.contains('/')) return normalized;
    return normalized.split('/').last.trim();
  }

  void applyInputFrame({
    required int seq,
    required int buttons,
    required String game,
  }) {
    _lastSeq = seq;
    _lastButtons = buttons;

    final dx = (buttons & (1 << 3)) != 0
        ? 1
        : (buttons & (1 << 2)) != 0
        ? -1
        : 0;
    final dy = (buttons & (1 << 1)) != 0
        ? 1
        : (buttons & (1 << 0)) != 0
        ? -1
        : 0;

    if (dx != 0 || dy != 0) {
      _cursorX = (_cursorX + dx).clamp(0, 63);
      _cursorY = (_cursorY + dy).clamp(0, 63);
    }

    final aPressed = (buttons & (1 << 4)) != 0;
    final bPressed = (buttons & (1 << 5)) != 0;

    var color = Colors.white;
    if (aPressed && bPressed) {
      color = Colors.purpleAccent;
    } else if (aPressed) {
      color = Colors.redAccent;
    } else if (bPressed) {
      color = Colors.blueAccent;
    } else if (game == 'dungeon') {
      color = Colors.greenAccent;
    }

    final idx = _cursorY * 64 + _cursorX;
    _matrix[idx] = color;

    // Add light fade trail effect so motion is easy to see in review.
    _fadeOneCell();

    notifyListeners();
  }

  void _fadeOneCell() {
    final firstNonBlack = _matrix.indexWhere((c) => c.toARGB32() != Colors.black.toARGB32());
    if (firstNonBlack < 0) return;

    final c = _matrix[firstNonBlack];
    final faded = Color.fromARGB(
      255,
      math.max(0, (c.r * 255 - 10).round()),
      math.max(0, (c.g * 255 - 10).round()),
      math.max(0, (c.b * 255 - 10).round()),
    );

    _matrix[firstNonBlack] = faded;
    if (faded.toARGB32() == const Color(0xFF000000).toARGB32()) {
      _matrix[firstNonBlack] = Colors.black;
    }
  }

  static Map<String, dynamic> _defaultSettings() {
    return {
      'panelName': 'Demo Panel',
      'gifs': true,
      'clock': true,
      'date': true,
      'weather': true,
      'radar': true,
      'radarTimeFormat': 'OFF',
      'radarUnitFormat': 'OFF',
      'radarZoomLevel': 7,
      'iss': true,
      'planes': true,
      'earthquake': true,
      'spotify': true,
      'spotifyShowOnPause': true,
      'spotifyShowOnlyAlbumArt': false,
      'diags': true,
      'textblast': true,
      'textBlastTextScale': 1,
      'textBlastText': 'Demo Mode Ready',
      'textBlastTextColor': 0x00FFFF00,
      'textBlastBackgroundColor': 0x00000000,
      'textBlastTextCustomMessage': false,
      'textBlastCycles': 1,
      'textBlastSpeed': 40.0,
      'doodles': true,
      'lat': 34.16,
      'lng': -84.80,
      'osUser': '',
      'osPass': '',
      'spotifyRefreshToken': '',
      'brightness': 128,
      'nightMode': false,
      'nightStart': 22,
      'nightEnd': 6,
      'transitionTime': 10,
    };
  }
}

class DemoRemoteGif {
  DemoRemoteGif({required this.bytes, required this.enabled});

  Uint8List bytes;
  bool enabled;
}
