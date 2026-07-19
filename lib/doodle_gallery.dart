import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'doodle_editor.dart';
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
  const DoodleGallery({super.key});

  @override
  State<DoodleGallery> createState() => _DoodleGalleryState();
}

class _DoodleGalleryState extends State<DoodleGallery> {
  final RGBopMdnsService _mdnsService = RGBopMdnsService();

  List<DoodleItem> _doodles = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  double _syncProgress = 0;
  String _syncStatus = '';

  @override
  void initState() {
    super.initState();
    _loadAllDoodles();
  }

  Future<String> _resolvePanelBaseUrl() async {
    try {
      final ip = await _mdnsService.findPanelIp().timeout(
        const Duration(seconds: 8),
      );
      if (ip != null) return 'http://$ip';
    } catch (_) {
      // Fall back to hostname for networks where mDNS name resolution still works.
    }
    return 'http://rgbop.local';
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

      map[name] = DoodleItem(
        filename: name,
        isLocal: true,
        isRemote: false,
        localFile: file,
        pixels: pixels,
      );
    }

    final baseUrl = await _resolvePanelBaseUrl();
    final remoteNames = await _fetchRemoteDoodleNames(baseUrl);

    for (final remoteName in remoteNames) {
      if (map.containsKey(remoteName)) {
        final existing = map[remoteName]!;
        map[remoteName] = DoodleItem(
          filename: remoteName,
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

      map[remoteName] = DoodleItem(
        filename: remoteName,
        isLocal: false,
        isRemote: true,
        pixels: remotePixels,
      );
    }

    final doodles = map.values.toList()
      ..sort(
        (a, b) => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()),
      );

    if (!mounted) return;
    setState(() {
      _doodles = doodles;
      _isLoading = false;
    });
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

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
    } catch (e) {
      _showSnack('Failed to delete local doodle: $e');
    }
  }

  Future<void> _importRemoteDoodle(DoodleItem doodle) async {
    if (doodle.isLocal || !doodle.isRemote) return;

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
        _showSnack('Sync complete: uploaded ${localFiles.length}.');
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

  Future<void> _openLocalEditor(DoodleItem doodle) async {
    if (!doodle.isLocal) {
      _showSnack('Import this remote doodle first to edit locally.');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('My Doodles'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAllDoodles,
          ),
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: _isSyncing ? null : _syncLocalToPanel,
            tooltip: 'Sync local doodles to panel',
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DoodleEditor()),
              );
              await _loadAllDoodles();
            },
          ),
        ],
      ),
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
                Expanded(
                  child: _doodles.isEmpty
                      ? const Center(
                          child: Text(
                            'No doodles yet. Create one with +',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                          itemCount: _doodles.length,
                          itemBuilder: (context, index) {
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
                                      if (!doodle.isLocal && doodle.isRemote)
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
