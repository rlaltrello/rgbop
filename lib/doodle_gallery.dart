import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'doodle_editor.dart';
import 'panel_storage_info.dart';
import 'rgbop_mdns_service.dart';

class DoodleItem {
  final String filename;
  final bool isLocal;
  final bool isRemote;
  final File? localFile;
  final List<Color>? pixels;

  DoodleItem({
    required this.filename,
    required this.isLocal,
    required this.isRemote,
    this.localFile,
    this.pixels,
  });
}

class DoodleGallery extends StatefulWidget {
  final String? panelIp;
  final bool offlineMode;

  const DoodleGallery({
    super.key,
    this.panelIp,
    this.offlineMode = false,
  });

  @override
  State<DoodleGallery> createState() => _DoodleGalleryState();
}

class _DoodleGalleryState extends State<DoodleGallery> {
  final RGBopMdnsService _mdnsService = RGBopMdnsService();
  static const double _snackBarLaneHeight = 76;

  List<DoodleItem> _doodles = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  double _syncProgress = 0;
  String _syncStatus = '';
  PanelStorageInfo? _storageInfo;
  String? _messageText;
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    _loadAllDoodles();
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    super.dispose();
  }

  bool get _isOffline {
    final routeIp = widget.panelIp?.trim();
    return widget.offlineMode || routeIp == null || routeIp.isEmpty;
  }

  Future<String> _resolvePanelBaseUrl() async {
    final routeIp = widget.panelIp?.trim();
    if (routeIp != null && routeIp.isNotEmpty) {
      return 'http://$routeIp';
    }

    try {
      final ip = await _mdnsService.findPanelIp().timeout(
        const Duration(seconds: 8),
      );
      if (ip != null) return 'http://$ip';
    } catch (_) {
      // Keep fallback discovery silent to preserve local-first workflows.
    }

    throw Exception(
      'No panel target available. Pick a panel from the main screen first.',
    );
  }

  Future<List<String>> _fetchRemoteDoodleNames(String baseUrl) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/api/doodle/list'))
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List) {
          return decoded.map((e) => e.toString()).toList();
        }
      }
    } catch (_) {
      // Treat unavailable panel as no remote list for local-first workflows.
    }
    return [];
  }

  Future<void> _loadAllDoodles() async {
    setState(() => _isLoading = true);

    final map = <String, DoodleItem>{};

    final dir = await getApplicationDocumentsDirectory();
    final files = dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.bin'),
    );

    for (final file in files) {
      final name = file.path.split('/').last;
      List<Color>? pixels;
      try {
        pixels = _parseRGB565(await file.readAsBytes());
      } catch (_) {
        pixels = null;
      }

      final key = _canonicalDoodleKey(name);
      map[key] = DoodleItem(
        filename: name,
        isLocal: true,
        isRemote: false,
        localFile: file,
        pixels: pixels,
      );
    }

    PanelStorageInfo? storageInfo;
    if (!_isOffline) {
      try {
        final baseUrl = await _resolvePanelBaseUrl();
        final remoteNames = await _fetchRemoteDoodleNames(baseUrl);
        storageInfo = await _fetchStorageInfo(baseUrl);

        for (final rawRemoteName in remoteNames) {
          final remoteName = _normalizeDoodleFilename(rawRemoteName);
          if (remoteName.isEmpty) continue;

          final key = _canonicalDoodleKey(remoteName);
          if (map.containsKey(key)) {
            final existing = map[key]!;
            map[key] = DoodleItem(
              // Keep local filename spelling/case when available.
              filename: existing.filename,
              isLocal: true,
              isRemote: true,
              localFile: existing.localFile,
              pixels: existing.pixels,
            );
            continue;
          }

          List<Color>? remotePixels;
          try {
            final thumb = await http
                .get(
                  Uri.parse(
                    '$baseUrl/api/doodle/download?name=${Uri.encodeComponent(remoteName)}',
                  ),
                )
                .timeout(const Duration(seconds: 6));

            if (thumb.statusCode == 200) {
              remotePixels = _parseRGB565(thumb.bodyBytes);
            }
          } catch (_) {
            remotePixels = null;
          }

          map[key] = DoodleItem(
            filename: remoteName,
            isLocal: false,
            isRemote: true,
            pixels: remotePixels,
          );
        }
      } catch (_) {
        // Keep local-only behavior available when panel reachability fails.
      }
    }

    final doodles = map.values.toList()
      ..sort(
        (a, b) => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()),
      );

    if (!mounted) return;
    setState(() {
      _doodles = doodles;
      _storageInfo = storageInfo;
      _isLoading = false;
    });
  }

  Future<PanelStorageInfo?> _fetchStorageInfo(String baseUrl) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/api/fs/info'))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return null;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      return PanelStorageInfo.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  List<Color> _parseRGB565(List<int> bytes) {
    final pixels = <Color>[];
    final safeLength = bytes.length - (bytes.length % 2);

    for (int i = 0; i < safeLength; i += 2) {
      final rgb565 = (bytes[i] << 8) | bytes[i + 1];
      final r = (((rgb565 >> 11) & 0x1F) * 255) ~/ 31;
      final g = (((rgb565 >> 5) & 0x3F) * 255) ~/ 63;
      final b = ((rgb565 & 0x1F) * 255) ~/ 31;
      pixels.add(Color.fromARGB(255, r, g, b));
    }

    return pixels;
  }

  String _normalizeDoodleFilename(String? value) {
    if (value == null) return '';

    var normalized = value.trim();
    if (normalized.isEmpty) return '';

    try {
      normalized = Uri.decodeComponent(normalized);
    } catch (_) {
      // Keep original when decode fails.
    }

    normalized = normalized.replaceAll('\\', '/');
    if (normalized.contains('/')) {
      normalized = normalized.split('/').last;
    }

    return normalized.trim();
  }

  String _canonicalDoodleKey(String filename) {
    final normalized = _normalizeDoodleFilename(filename);
    return normalized.toLowerCase();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    _messageTimer?.cancel();
    setState(() {
      _messageText = message;
    });
    _messageTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() {
        _messageText = null;
      });
    });
  }

  Widget _buildMessageLane() {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return SafeArea(
      top: false,
      child: SizedBox(
        height: _snackBarLaneHeight,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, bottomInset > 0 ? 8 : 12),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _messageText == null
                ? const SizedBox.expand(key: ValueKey('empty-message'))
                : Material(
                    key: const ValueKey('active-message'),
                    color: const Color(0xFFE3DCE6),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _messageText!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF3F3845),
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteLocalDoodle(DoodleItem doodle) async {
    if (!doodle.isLocal) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Delete Local Doodle?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This removes it from local storage only. The panel copy (if any) remains until you press SYNC.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      if (doodle.localFile != null && await doodle.localFile!.exists()) {
        await doodle.localFile!.delete();
      }
      await _loadAllDoodles();
      _showSnack('Deleted ${doodle.filename} from local storage.');
    } catch (e) {
      _showSnack('Failed to delete local doodle: $e');
    }
  }

  Future<void> _importRemoteDoodle(DoodleItem doodle) async {
    if (doodle.isLocal || !doodle.isRemote) return;
    if (_isOffline) {
      _showSnack('Offline mode: connect to a panel to import remote doodles.');
      return;
    }

    try {
      final baseUrl = await _resolvePanelBaseUrl();
      final response = await http
          .get(
            Uri.parse(
              '$baseUrl/api/doodle/download?name=${Uri.encodeComponent(doodle.filename)}',
            ),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        _showSnack('Import failed (${response.statusCode}).');
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${doodle.filename}');
      await file.writeAsBytes(response.bodyBytes, flush: true);

      _showSnack('Imported ${doodle.filename} to local storage.');
      await _loadAllDoodles();
    } catch (e) {
      _showSnack('Import failed: $e');
    }
  }

  Future<void> _syncLocalToPanel() async {
    if (_isSyncing) return;
    if (_isOffline) {
      _showSnack('Offline mode: connect to a panel to sync doodles.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Sync Local Doodles?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This will clear doodles on the panel, then upload all local doodles from this app.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('SYNC'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isSyncing = true;
      _syncProgress = 0;
      _syncStatus = 'Preparing sync...';
    });

    final failed = <String>[];
    final deletedSurvivors = <String>[];

    try {
      final baseUrl = await _resolvePanelBaseUrl();
      final dir = await getApplicationDocumentsDirectory();
      final localFiles = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.bin'))
          .toList();

      setState(() => _syncStatus = 'Clearing panel doodles...');
      final clearResponse = await http
          .post(Uri.parse('$baseUrl/api/doodle/clear'))
          .timeout(const Duration(seconds: 10));

      if (clearResponse.statusCode != 200 && clearResponse.statusCode != 404) {
        throw Exception('Panel clear failed (${clearResponse.statusCode}).');
      }

      for (int i = 0; i < localFiles.length; i++) {
        final file = localFiles[i];
        final name = file.path.split('/').last;
        setState(() {
          _syncStatus = 'Uploading $name (${i + 1}/${localFiles.length})';
        });

        try {
          final bytes = await file.readAsBytes();
          final request = http.MultipartRequest(
            'POST',
            Uri.parse('$baseUrl/api/doodle/upload'),
          );
          request.files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: name),
          );

          final response = await request.send();
          if (response.statusCode != 200) {
            failed.add(name);
          }
        } catch (_) {
          failed.add(name);
        }

        if (mounted) {
          setState(() {
            _syncProgress = localFiles.isEmpty
                ? 1
                : (i + 1) / localFiles.length;
          });
        }
      }

      // Enforce local-as-source-of-truth: remove any remote leftovers
      // that survived clear but are not present in local storage.
      setState(() => _syncStatus = 'Reconciling remote leftovers...');
      final localKeys = localFiles
          .map((f) => _canonicalDoodleKey(f.path.split('/').last))
          .toSet();
      final remoteNames = await _fetchRemoteDoodleNames(baseUrl);
      for (final rawName in remoteNames) {
        final normalized = _normalizeDoodleFilename(rawName);
        if (normalized.isEmpty) continue;
        if (localKeys.contains(_canonicalDoodleKey(normalized))) continue;

        final deleted = await _deleteRemoteDoodle(baseUrl, normalized);
        if (deleted) {
          deletedSurvivors.add(normalized);
        }
      }

      final afterCleanup = await _fetchRemoteDoodleNames(baseUrl);
      final remainingSurvivors = afterCleanup
          .map(_normalizeDoodleFilename)
          .where((n) => n.isNotEmpty)
          .where((n) => !localKeys.contains(_canonicalDoodleKey(n)))
          .toList();

      if (mounted) {
        setState(() {
          _syncStatus = failed.isEmpty
              ? 'Sync complete. Uploaded ${localFiles.length} doodles.'
              : 'Sync finished with ${failed.length} failed upload(s).';
          _syncProgress = 1;
        });
      }

      await _loadAllDoodles();

      if (failed.isEmpty) {
        if (remainingSurvivors.isEmpty) {
          if (deletedSurvivors.isEmpty) {
            _showSnack('Sync complete: uploaded ${localFiles.length}.');
          } else {
            _showSnack(
              'Sync complete: uploaded ${localFiles.length}, removed ${deletedSurvivors.length} leftover remote doodle(s).',
            );
          }
        } else {
          _showSnack(
            'Sync uploaded ${localFiles.length}, removed ${deletedSurvivors.length}, but ${remainingSurvivors.length} remote leftover doodle(s) remain.',
          );
        }
      } else {
        _showSnack('Sync finished with failures: ${failed.join(', ')}');
      }
    } catch (e) {
      _showSnack('Sync failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  Future<bool> _deleteRemoteDoodle(String baseUrl, String filename) async {
    final normalized = _normalizeDoodleFilename(filename);
    if (normalized.isEmpty) return false;

    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/api/doodle/delete'),
            body: {'name': normalized},
          )
          .timeout(const Duration(seconds: 6));
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openLocalEditor(DoodleItem doodle) async {
    if (!doodle.isLocal) {
      _showSnack(
        _isOffline
            ? 'This doodle is remote-only. Reconnect to import it locally first.'
            : 'Import this remote doodle first to edit locally.',
      );
      return;
    }

    final pixels = doodle.pixels;
    final file = doodle.localFile;
    if (pixels == null || file == null) {
      _showSnack('Local doodle data is missing or unreadable.');
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DoodleEditor(existingFile: file, initialPixels: pixels),
      ),
    );

    await _loadAllDoodles();
  }

  Future<void> _createDoodle() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DoodleEditor()),
    );
    await _loadAllDoodles();
  }

  Widget _buildAddTile() {
    return GestureDetector(
      onTap: _createDoodle,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.blueAccent),
          color: const Color(0xFF151515),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.add_box_outlined, color: Colors.blueAccent, size: 42),
            SizedBox(height: 10),
            Text(
              'Add Doodle',
              style: TextStyle(
                color: Colors.blueAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: Text(_isOffline ? 'My Doodles (Offline)' : 'My Doodles'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAllDoodles,
          ),
          if (!_isOffline)
            IconButton(
              icon: const Icon(Icons.sync),
              onPressed: _isSyncing ? null : _syncLocalToPanel,
              tooltip: 'Sync local doodles to panel',
            ),
          IconButton(icon: const Icon(Icons.add), onPressed: _createDoodle),
        ],
      ),
      bottomNavigationBar: _buildMessageLane(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_isSyncing || _syncStatus.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _syncStatus,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: _isSyncing ? _syncProgress : 1.0,
                        ),
                      ],
                    ),
                  ),
                if (!_isOffline && _storageInfo != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: PanelStorageSection(info: _storageInfo!),
                  ),
                Expanded(
                  child: _doodles.isEmpty
                      ? const Center(
                          child: Text(
                            'No doodles yet. Create one with +',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : GridView.builder(
                          padding: EdgeInsets.fromLTRB(16, 16, 16, 16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                          itemCount: _doodles.length + 1,
                          itemBuilder: (context, index) {
                            if (index == _doodles.length) {
                              return _buildAddTile();
                            }

                            final doodle = _doodles[index];
                            final borderColor = doodle.isLocal
                                ? (doodle.isRemote
                                      ? Colors.amber
                                      : Colors.green)
                                : Colors.blue;

                            return GestureDetector(
                              onTap: () => _openLocalEditor(doodle),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  return Stack(
                                    children: [
                                      Container(
                                        width: constraints.maxWidth,
                                        height: constraints.maxHeight,
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: borderColor,
                                          ),
                                        ),
                                        child: doodle.pixels != null
                                            ? CustomPaint(
                                                painter: PixelGridPainter(
                                                  doodle.pixels!,
                                                  64,
                                                  false,
                                                  Offset.zero,
                                                ),
                                              )
                                            : Center(
                                                child: Icon(
                                                  doodle.isLocal
                                                      ? Icons
                                                            .image_not_supported
                                                      : Icons.cloud_download,
                                                  color: borderColor,
                                                ),
                                              ),
                                      ),
                                      Positioned(
                                        top: 4,
                                        left: 4,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black54,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            doodle.isLocal
                                                ? (doodle.isRemote
                                                      ? 'LOCAL+REMOTE'
                                                      : 'LOCAL')
                                                : 'REMOTE',
                                            style: TextStyle(
                                              color: borderColor,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (doodle.isLocal)
                                        Positioned(
                                          right: 4,
                                          bottom: 4,
                                          child: GestureDetector(
                                            onTap: () =>
                                                _confirmDeleteLocalDoodle(
                                                  doodle,
                                                ),
                                            child: Container(
                                              padding: const EdgeInsets.all(4),
                                              decoration: BoxDecoration(
                                                color: Colors.black54,
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: const Icon(
                                                Icons.delete,
                                                color: Colors.redAccent,
                                                size: 16,
                                              ),
                                            ),
                                          ),
                                        ),
                                      if (!_isOffline &&
                                          !doodle.isLocal &&
                                          doodle.isRemote)
                                        Positioned(
                                          right: 4,
                                          bottom: 4,
                                          child: GestureDetector(
                                            onTap: () =>
                                                _importRemoteDoodle(doodle),
                                            child: Container(
                                              padding: const EdgeInsets.all(4),
                                              decoration: BoxDecoration(
                                                color: Colors.black54,
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: const Icon(
                                                Icons.download,
                                                color: Colors.blueAccent,
                                                size: 16,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
