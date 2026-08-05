import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'app_palette.dart';
import 'demo/demo_mode_controller.dart';
import 'panel_storage_info.dart';

enum _GifImportMode { preserveOriginal, fitTo64 }

class _GifImportResult {
  final List<int> bytes;
  final bool transformed;
  final int sourceWidth;
  final int sourceHeight;
  final int sourceFrames;
  final int outputFrames;
  final bool wasTrimmed;

  const _GifImportResult({
    required this.bytes,
    required this.transformed,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.sourceFrames,
    required this.outputFrames,
    required this.wasTrimmed,
  });
}

class GifItem {
  final String filename;
  final bool isLocal;
  final bool isRemote;
  final File? localFile;
  final int? remoteSize;
  final bool remoteEnabled;

  const GifItem({
    required this.filename,
    required this.isLocal,
    required this.isRemote,
    this.localFile,
    this.remoteSize,
    this.remoteEnabled = true,
  });
}

class GifManagerScreen extends StatefulWidget {
  final String? panelIp;
  final bool offlineMode;

  const GifManagerScreen({super.key, this.panelIp, this.offlineMode = false});

  @override
  State<GifManagerScreen> createState() => _GifManagerScreenState();
}

class _GifManagerScreenState extends State<GifManagerScreen> {
  static const int _expectedGifWidth = 64;
  static const int _expectedGifHeight = 64;
  static const int _maxProcessFrames = 150;
  static const int _maxProcessDurationMs = 10000;
  static const double _snackBarLaneHeight = 76;

  List<GifItem> _gifs = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  double _syncProgress = 0;
  String _syncStatus = '';
  PanelStorageInfo? _storageInfo;
  String? _messageText;
  Timer? _messageTimer;
  bool _isProcessingImport = false;
  final Map<String, Uint8List> _localPreviewCache = {};
  final Map<String, Uint8List> _remotePreviewCache = {};

  @override
  void initState() {
    super.initState();
    _loadAllGifs();
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    super.dispose();
  }

  bool get _isOffline {
    final ip = widget.panelIp?.trim();
    return widget.offlineMode || ip == null || ip.isEmpty;
  }

  bool get _isDemoMode {
    return DemoModeController.instance.isEnabled &&
        (widget.offlineMode ||
            DemoModeController.instance.isDemoIp(widget.panelIp));
  }

  String? get _baseUrl {
    final ip = widget.panelIp?.trim();
    if (ip == null || ip.isEmpty) return null;
    return 'http://$ip';
  }

  Future<Directory> _localGifDirectory() async {
    final documentsDir = await getApplicationDocumentsDirectory();
    final gifDir = Directory('${documentsDir.path}/gifs');
    if (!await gifDir.exists()) {
      await gifDir.create(recursive: true);
    }
    return gifDir;
  }

  Future<void> _loadAllGifs() async {
    setState(() => _isLoading = true);
    _localPreviewCache.clear();
    _remotePreviewCache.clear();

    if (_isDemoMode) {
      final itemsByName = <String, GifItem>{};
      final demo = DemoModeController.instance;

      for (final entry in demo.localGifs.entries) {
        final key = _canonicalGifKey(entry.key);
        itemsByName[key] = GifItem(
          filename: entry.key,
          isLocal: true,
          isRemote: false,
          remoteSize: entry.value.length,
          remoteEnabled: true,
        );
      }

      for (final entry in demo.remoteGifs.entries) {
        final key = _canonicalGifKey(entry.key);
        final existing = itemsByName[key];
        itemsByName[key] = GifItem(
          filename: existing?.filename ?? entry.key,
          isLocal: existing?.isLocal ?? false,
          isRemote: true,
          localFile: existing?.localFile,
          remoteSize: entry.value.bytes.length,
          remoteEnabled: entry.value.enabled,
        );
      }

      final gifs =
          itemsByName.values
              .where(
                (gif) => !(gif.isRemote && !gif.isLocal && !gif.remoteEnabled),
              )
              .toList()
            ..sort(
              (a, b) =>
                  a.filename.toLowerCase().compareTo(b.filename.toLowerCase()),
            );

      if (!mounted) return;
      setState(() {
        _gifs = gifs;
        _storageInfo = null;
        _isLoading = false;
      });
      return;
    }

    final itemsByName = <String, GifItem>{};
    final gifDir = await _localGifDirectory();
    final localFiles = gifDir.listSync().whereType<File>().where(
      (file) => file.path.toLowerCase().endsWith('.gif'),
    );

    for (final file in localFiles) {
      final name = file.path.split('/').last;
      final key = _canonicalGifKey(name);
      itemsByName[key] = GifItem(
        filename: name,
        isLocal: true,
        isRemote: false,
        localFile: file,
      );
    }

    PanelStorageInfo? storageInfo;
    final baseUrl = _baseUrl;

    if (!_isOffline && baseUrl != null) {
      try {
        final response = await http
            .get(Uri.parse('$baseUrl/api/gifs'))
            .timeout(const Duration(seconds: 6));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          final remoteGifs = decoded is Map<String, dynamic>
              ? decoded['gifs'] as List<dynamic>? ?? const []
              : const [];

          for (final entry in remoteGifs) {
            if (entry is! Map) continue;

            final rawFilename = entry['name']?.toString();
            final filename = _normalizeGifFilename(rawFilename);
            if (filename.isEmpty) continue;

            final key = _canonicalGifKey(filename);
            final existing = itemsByName[key];
            final parsedSize = _parseRemoteSize(entry['size']);
            itemsByName[key] = GifItem(
              // Prefer local filename spelling/case when available.
              filename: existing?.filename ?? filename,
              isLocal: existing?.isLocal ?? false,
              isRemote: true,
              localFile: existing?.localFile,
              remoteSize: parsedSize ?? existing?.remoteSize,
              // If the backend returns duplicate variants, keep visible if any are enabled.
              remoteEnabled: (existing?.isRemote ?? false)
                  ? (existing!.remoteEnabled || entry['enabled'] != false)
                  : (entry['enabled'] != false),
            );
          }
        }
      } catch (_) {
        // Keep local-first workflows available even when the panel is offline.
      }

      storageInfo = await _fetchStorageInfo(baseUrl);
    }

    final gifs =
        itemsByName.values
            .where(
              (gif) => !(gif.isRemote && !gif.isLocal && !gif.remoteEnabled),
            )
            .toList()
          ..sort(
            (a, b) =>
                a.filename.toLowerCase().compareTo(b.filename.toLowerCase()),
          );

    if (!mounted) return;
    setState(() {
      _gifs = gifs;
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

  int? _parseRemoteSize(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  String _normalizeGifFilename(String? value) {
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

  String _canonicalGifKey(String filename) {
    final normalized = _normalizeGifFilename(filename);
    return normalized.toLowerCase();
  }

  Future<void> _addLocalGif() async {
    if (_isProcessingImport) return;

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['gif'],
    );

    final sourcePath = result?.files.single.path;
    if (sourcePath == null) return;

    try {
      setState(() {
        _isProcessingImport = true;
      });

      final sourceBytes = await File(sourcePath).readAsBytes();
      final decoded = img.decodeGif(sourceBytes);
      if (decoded == null) {
        throw Exception('Could not decode GIF data.');
      }

      final importMode =
          decoded.width > _expectedGifWidth ||
              decoded.height > _expectedGifHeight
          ? _GifImportMode.fitTo64
          : _GifImportMode.preserveOriginal;

      final gifDir = await _localGifDirectory();
      final filename = sourcePath.split('/').last;
      final prepared = await _prepareGifForLocalSave(
        sourcePath,
        importMode,
        sourceBytes: sourceBytes,
        decodedGif: decoded,
      );

      if (_isDemoMode) {
        DemoModeController.instance.saveLocalGif(
          filename,
          Uint8List.fromList(prepared.bytes),
        );
      } else {
        final destination = File('${gifDir.path}/$filename');

        final tempPath = '${destination.path}.tmp';
        final tempFile = File(tempPath);
        await tempFile.writeAsBytes(prepared.bytes, flush: true);
        if (await destination.exists()) {
          await destination.delete();
        }
        await tempFile.rename(destination.path);
      }

      if (!prepared.transformed) {
        if (importMode == _GifImportMode.preserveOriginal &&
            (prepared.sourceWidth != _expectedGifWidth ||
                prepared.sourceHeight != _expectedGifHeight)) {
          _showSnack(
            'Saved original $filename (${prepared.sourceWidth}x${prepared.sourceHeight}) with source colors preserved.',
          );
        } else {
          _showSnack('Saved $filename to local GIF storage.');
        }
      } else if (prepared.wasTrimmed) {
        _showSnack(
          'Saved $filename (${prepared.sourceWidth}x${prepared.sourceHeight} -> '
          '64x64, ${prepared.outputFrames}/${prepared.sourceFrames} frames).',
        );
      } else {
        _showSnack(
          'Saved $filename (${prepared.sourceWidth}x${prepared.sourceHeight} -> 64x64).',
        );
      }

      await _loadAllGifs();
    } catch (e) {
      _showSnack('Failed to save GIF locally: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessingImport = false;
        });
      }
    }
  }

  Future<_GifImportResult> _prepareGifForLocalSave(
    String sourcePath,
    _GifImportMode importMode, {
    Uint8List? sourceBytes,
    img.Image? decodedGif,
  }) async {
    final bytes = sourceBytes ?? await File(sourcePath).readAsBytes();
    final decoded = decodedGif ?? img.decodeGif(bytes);
    if (decoded == null) {
      throw Exception('Could not decode GIF data.');
    }

    final sourceWidth = decoded.width;
    final sourceHeight = decoded.height;
    final sourceFrames = decoded.numFrames;

    if (importMode == _GifImportMode.preserveOriginal) {
      return _GifImportResult(
        bytes: bytes,
        transformed: false,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        sourceFrames: sourceFrames,
        outputFrames: sourceFrames,
        wasTrimmed: false,
      );
    }

    if (sourceWidth == _expectedGifWidth &&
        sourceHeight == _expectedGifHeight) {
      return _GifImportResult(
        bytes: bytes,
        transformed: false,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        sourceFrames: sourceFrames,
        outputFrames: sourceFrames,
        wasTrimmed: false,
      );
    }

    var processedFrames = 0;
    var durationMs = 0;
    img.Image? transformedRoot;

    for (var i = 0; i < decoded.numFrames; i++) {
      if (processedFrames >= _maxProcessFrames) break;

      final sourceFrame = decoded.getFrame(i);
      // Some GIFs use 0ms/very low frame delays that can be unstable across decoders.
      final sourceFrameDuration = sourceFrame.frameDuration;
      final frameDuration = sourceFrameDuration <= 0
          ? 100
          : math.max(sourceFrameDuration, 20);

      if (processedFrames > 0 && durationMs >= _maxProcessDurationMs) {
        break;
      }

      final transformedPixels = _transformFrameFillTo64(sourceFrame);
      // Ensure each encoded frame is a standalone frame (no inherited animation list).
      final transformedFrame = img.Image.from(
        transformedPixels,
        noAnimation: true,
      )..frameDuration = frameDuration;

      if (transformedRoot == null) {
        transformedRoot = img.Image.from(transformedFrame, noAnimation: true)
          ..frameDuration = frameDuration
          ..loopCount = decoded.loopCount <= 0 ? 0 : decoded.loopCount
          ..frameType = img.FrameType.animation;
      } else {
        transformedRoot.addFrame(transformedFrame);
      }

      processedFrames++;
      durationMs += frameDuration;
    }

    if (transformedRoot == null) {
      throw Exception('GIF has no decodable frames.');
    }

    final encodedBytes = img.encodeGif(transformedRoot);
    final wasTrimmed =
        processedFrames < sourceFrames || durationMs >= _maxProcessDurationMs;

    return _GifImportResult(
      bytes: encodedBytes,
      transformed: true,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      sourceFrames: sourceFrames,
      outputFrames: processedFrames,
      wasTrimmed: wasTrimmed,
    );
  }

  img.Image _transformFrameFillTo64(img.Image frame) {
    final side = math.min(frame.width, frame.height);
    final cropX = ((frame.width - side) / 2).floor();
    final cropY = ((frame.height - side) / 2).floor();

    final square = img.copyCrop(
      frame,
      x: cropX,
      y: cropY,
      width: side,
      height: side,
    );

    return img.copyResize(
      square,
      width: _expectedGifWidth,
      height: _expectedGifHeight,
      interpolation: img.Interpolation.nearest,
    );
  }

  Future<void> _confirmDeleteLocalGif(GifItem gif) async {
    if (!gif.isLocal) return;

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colorScheme.surfaceContainerHighest,
        title: Text(
          'Delete Local GIF?',
          style: TextStyle(color: colorScheme.onSurface),
        ),
        content: Text(
          'This removes it from local storage only. The panel copy remains until you press SYNC.',
          style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.7)),
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
              style: TextStyle(color: AppPalette.statusDanger),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      if (_isDemoMode) {
        DemoModeController.instance.deleteLocalGif(gif.filename);
      } else if (gif.localFile != null && await gif.localFile!.exists()) {
        await gif.localFile!.delete();
      }
      await _loadAllGifs();
      _showSnack('Deleted ${gif.filename} from local storage.');
    } catch (e) {
      _showSnack('Failed to delete local GIF: $e');
    }
  }

  Future<void> _importRemoteGif(GifItem gif) async {
    if (gif.isLocal || !gif.isRemote) return;
    if (_isDemoMode) {
      final imported = DemoModeController.instance.importRemoteGifToLocal(
        gif.filename,
      );
      if (imported) {
        _showSnack('Imported ${gif.filename} to local storage.');
        await _loadAllGifs();
      } else {
        _showSnack('Import failed. Demo remote GIF not found.');
      }
      return;
    }

    if (_isOffline) {
      _showSnack('Offline mode: connect to a panel to import remote GIFs.');
      return;
    }

    final baseUrl = _baseUrl;
    if (baseUrl == null) {
      _showSnack('No panel target available.');
      return;
    }

    try {
      final response = await http
          .get(Uri.parse('$baseUrl/gifs/${Uri.encodeComponent(gif.filename)}'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        _showSnack('Import failed (${response.statusCode}).');
        return;
      }

      final gifDir = await _localGifDirectory();
      final file = File('${gifDir.path}/${gif.filename}');
      await file.writeAsBytes(response.bodyBytes, flush: true);

      _showSnack('Imported ${gif.filename} to local storage.');
      await _loadAllGifs();
    } catch (e) {
      _showSnack('Import failed: $e');
    }
  }

  Future<void> _toggleRemoteGif(GifItem gif) async {
    if (!gif.isRemote) return;
    if (_isDemoMode) {
      final ok = DemoModeController.instance.toggleRemoteGif(
        gif.filename,
        !gif.remoteEnabled,
      );
      if (ok) {
        await _loadAllGifs();
      } else {
        _showSnack('Failed to toggle GIF state.');
      }
      return;
    }

    if (_isOffline) {
      _showSnack('Offline mode: connect to a panel to toggle GIF visibility.');
      return;
    }

    final baseUrl = _baseUrl;
    if (baseUrl == null) {
      _showSnack('No panel target available.');
      return;
    }

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/gifs/toggle'),
        body: {
          'name': gif.filename,
          'enabled': (!gif.remoteEnabled).toString(),
        },
      );

      if (response.statusCode == 200) {
        await _loadAllGifs();
      } else {
        _showSnack('Failed to toggle GIF state.');
      }
    } catch (e) {
      _showSnack('Network error while toggling: $e');
    }
  }

  Future<void> _syncLocalToPanel() async {
    if (_isSyncing) return;
    if (_isDemoMode) {
      setState(() {
        _isSyncing = true;
        _syncProgress = 0;
        _syncStatus = 'Syncing demo GIF store...';
      });
      DemoModeController.instance.syncLocalGifsToRemote();
      if (mounted) {
        setState(() {
          _syncProgress = 1;
          _syncStatus = 'Sync complete. Uploaded local GIFs to demo panel.';
          _isSyncing = false;
        });
      }
      await _loadAllGifs();
      _showSnack('Demo sync complete.');
      return;
    }

    if (_isOffline) {
      _showSnack('Offline mode: connect to a panel to sync GIFs.');
      return;
    }

    final baseUrl = _baseUrl;
    if (baseUrl == null) {
      _showSnack('No panel target available.');
      return;
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colorScheme.surfaceContainerHighest,
        title: Text(
          'Sync Local GIFs?',
          style: TextStyle(color: colorScheme.onSurface),
        ),
        content: Text(
          'This will clear GIFs on the panel, then upload all local GIFs from this app.',
          style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.7)),
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
    final undeletedSurvivors = <String>[];

    try {
      final gifDir = await _localGifDirectory();
      final localFiles = gifDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.gif'))
          .toList();

      setState(() => _syncStatus = 'Clearing panel GIFs...');
      final clearResponse = await http
          .post(Uri.parse('$baseUrl/api/gifs/clear'))
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
          final request = http.MultipartRequest(
            'POST',
            Uri.parse('$baseUrl/api/gifs/upload'),
          );
          request.files.add(
            await http.MultipartFile.fromPath('file', file.path),
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
      // that survived panel clear but are not in local storage.
      setState(() => _syncStatus = 'Reconciling remote leftovers...');
      final localKeys = localFiles
          .map((f) => _canonicalGifKey(f.path.split('/').last))
          .toSet();
      final remoteNames = await _fetchRemoteGifNames(baseUrl);
      for (final remoteName in remoteNames) {
        final key = _canonicalGifKey(remoteName);
        if (localKeys.contains(key)) continue;

        final deleted = await _deleteRemoteGif(baseUrl, remoteName);
        if (deleted) {
          deletedSurvivors.add(remoteName);
        } else {
          undeletedSurvivors.add(remoteName);
        }
      }

      final afterCleanupNames = await _fetchRemoteGifNames(baseUrl);
      final remainingSurvivors = afterCleanupNames
          .where((name) => !localKeys.contains(_canonicalGifKey(name)))
          .toList();

      if (mounted) {
        setState(() {
          _syncStatus = failed.isEmpty
              ? 'Sync complete. Uploaded ${localFiles.length} GIFs.'
              : 'Sync finished with ${failed.length} failed upload(s).';
          _syncProgress = 1;
        });
      }

      await _loadAllGifs();

      if (failed.isEmpty) {
        if (remainingSurvivors.isEmpty) {
          if (deletedSurvivors.isEmpty) {
            _showSnack('Sync complete: uploaded ${localFiles.length}.');
          } else {
            _showSnack(
              'Sync complete: uploaded ${localFiles.length}, removed ${deletedSurvivors.length} leftover remote GIF(s).',
            );
          }
        } else {
          _showSnack(
            'Sync uploaded ${localFiles.length}, removed ${deletedSurvivors.length}, but ${remainingSurvivors.length} remote leftover GIF(s) remain.',
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

  Future<List<String>> _fetchRemoteGifNames(String baseUrl) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/api/gifs'))
          .timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return const [];

      final entries = decoded['gifs'];
      if (entries is! List) return const [];

      final names = <String>[];
      for (final entry in entries) {
        if (entry is! Map) continue;
        final name = _normalizeGifFilename(entry['name']?.toString());
        if (name.isNotEmpty) {
          names.add(name);
        }
      }
      return names;
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _deleteRemoteGif(String baseUrl, String filename) async {
    final normalized = _normalizeGifFilename(filename);
    if (normalized.isEmpty) return false;

    // Firmware contract:
    // POST /api/gifs/delete with form arg `name=<filename>`.
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/api/gifs/delete'),
            body: {'name': normalized},
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode == 200 || response.statusCode == 204) {
        return true;
      }
    } catch (_) {
      // Fall through to compatibility attempts below.
    }

    final candidates = <Uri>[
      Uri.parse('$baseUrl/api/delete?file=${Uri.encodeComponent(normalized)}'),
      Uri.parse(
        '$baseUrl/api/delete?file=${Uri.encodeComponent('/gifs/$normalized')}',
      ),
      Uri.parse(
        '$baseUrl/api/gifs/delete?name=${Uri.encodeComponent(normalized)}',
      ),
      Uri.parse(
        '$baseUrl/api/gifs/delete?file=${Uri.encodeComponent(normalized)}',
      ),
    ];

    for (final uri in candidates) {
      try {
        final deleteResp = await http
            .delete(uri)
            .timeout(const Duration(seconds: 6));
        if (deleteResp.statusCode == 200 || deleteResp.statusCode == 204) {
          return true;
        }
      } catch (_) {
        // Try next candidate.
      }

      try {
        final postResp = await http
            .post(uri)
            .timeout(const Duration(seconds: 6));
        if (postResp.statusCode == 200 || postResp.statusCode == 204) {
          return true;
        }
      } catch (_) {
        // Try next candidate.
      }
    }

    return false;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
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
                    color: AppPalette.surfaceMessageLane,
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
                            color: AppPalette.onSurfaceMessageLane,
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

  Widget _buildGifPreview(GifItem gif) {
    if (_isDemoMode) {
      return FutureBuilder<Uint8List?>(
        future: _loadDemoPreviewBytes(gif),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) {
            return const Icon(Icons.broken_image, color: Colors.grey, size: 32);
          }
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.broken_image, color: Colors.grey, size: 32),
          );
        },
      );
    }

    final image = gif.isLocal && gif.localFile != null
        ? FutureBuilder<Uint8List?>(
            future: _loadLocalPreviewBytes(gif.localFile!),
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null) {
                return const Icon(
                  Icons.broken_image,
                  color: Colors.grey,
                  size: 32,
                );
              }
              return Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.broken_image,
                  color: Colors.grey,
                  size: 32,
                ),
              );
            },
          )
        : FutureBuilder<Uint8List?>(
            future: _loadRemotePreviewBytes(gif.filename),
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null) {
                return const Icon(
                  Icons.broken_image,
                  color: Colors.grey,
                  size: 32,
                );
              }
              return Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.broken_image,
                  color: Colors.grey,
                  size: 32,
                ),
              );
            },
          );

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: ColoredBox(
        color: AppPalette.surfacePanel.withValues(alpha: 0.5),
        child: Center(child: image),
      ),
    );
  }

  Future<Uint8List?> _loadDemoPreviewBytes(GifItem gif) async {
    final demo = DemoModeController.instance;
    final bytes = demo.getLocalGifBytes(gif.filename) ??
        demo.getRemoteGifBytes(gif.filename);
    if (bytes == null) return null;

    final decoded = img.decodeGif(bytes) ?? img.decodeImage(bytes);
    if (decoded == null) return null;
    final frame = decoded.hasAnimation ? decoded.getFrame(0) : decoded;
    return Uint8List.fromList(img.encodePng(frame));
  }

  Future<Uint8List?> _loadLocalPreviewBytes(File file) async {
    final path = file.path;
    final cached = _localPreviewCache[path];
    if (cached != null) return cached;

    try {
      final bytes = await file.readAsBytes();
      final decoded = img.decodeGif(bytes) ?? img.decodeImage(bytes);
      if (decoded == null) return null;

      final frame = decoded.hasAnimation ? decoded.getFrame(0) : decoded;
      final pngBytes = Uint8List.fromList(img.encodePng(frame));
      _localPreviewCache[path] = pngBytes;
      return pngBytes;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _loadRemotePreviewBytes(String filename) async {
    if (_isDemoMode) {
      final remote = DemoModeController.instance.getRemoteGifBytes(filename);
      if (remote == null) return null;
      final decoded = img.decodeGif(remote) ?? img.decodeImage(remote);
      if (decoded == null) return null;
      final frame = decoded.hasAnimation ? decoded.getFrame(0) : decoded;
      return Uint8List.fromList(img.encodePng(frame));
    }

    final cacheKey = _canonicalGifKey(filename);
    final cached = _remotePreviewCache[cacheKey];
    if (cached != null) return cached;

    final baseUrl = _baseUrl;
    if (baseUrl == null) return null;

    try {
      final response = await http
          .get(Uri.parse('$baseUrl/gifs/${Uri.encodeComponent(filename)}'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;

      final decoded =
          img.decodeGif(response.bodyBytes) ??
          img.decodeImage(response.bodyBytes);
      if (decoded == null) return null;

      final frame = decoded.hasAnimation ? decoded.getFrame(0) : decoded;
      final pngBytes = Uint8List.fromList(img.encodePng(frame));
      _remotePreviewCache[cacheKey] = pngBytes;
      return pngBytes;
    } catch (_) {
      return null;
    }
  }

  Color _borderColor(GifItem gif) {
    if (gif.isLocal && gif.isRemote) return AppPalette.statusWarning;
    if (gif.isLocal) return AppPalette.statusSuccess;
    return AppPalette.brandAccent;
  }

  String _stateLabel(GifItem gif) {
    if (gif.isLocal && gif.isRemote) return 'LOCAL+REMOTE';
    if (gif.isLocal) return 'LOCAL';
    return 'REMOTE';
  }

  Widget _buildAddTile() {
    return GestureDetector(
      onTap: _addLocalGif,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppPalette.brandAccent),
          color: AppPalette.surfaceTile,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(
              Icons.add_box_outlined,
              color: AppPalette.brandAccent,
              size: 42,
            ),
            SizedBox(height: 10),
            Text(
              'Add GIF',
              style: TextStyle(
                color: AppPalette.brandAccent,
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          _isDemoMode
              ? 'My GIFs (Demo)'
              : (_isOffline ? 'My GIFs (Offline)' : 'My GIFs'),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadAllGifs),
          if (!_isOffline || _isDemoMode)
            IconButton(
              icon: const Icon(Icons.sync),
              onPressed: _isSyncing ? null : _syncLocalToPanel,
              tooltip: 'Sync local GIFs to panel',
            ),
          _isProcessingImport
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _addLocalGif,
                ),
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
                          style: TextStyle(
                            color: colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: _isSyncing ? _syncProgress : 1.0,
                        ),
                      ],
                    ),
                  ),
                if (!_isOffline && !_isDemoMode && _storageInfo != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: PanelStorageSection(info: _storageInfo!),
                  ),
                Expanded(
                  child: _gifs.isEmpty
                      ? const Center(
                          child: Text(
                            'No GIFs yet. Add one with +',
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
                                childAspectRatio: 0.82,
                              ),
                          itemCount: _gifs.length + 1,
                          itemBuilder: (context, index) {
                            if (index == _gifs.length) {
                              return _buildAddTile();
                            }

                            final gif = _gifs[index];
                            final borderColor = _borderColor(gif);

                            return LayoutBuilder(
                              builder: (context, constraints) {
                                return Stack(
                                  children: [
                                    Container(
                                      width: constraints.maxWidth,
                                      height: constraints.maxHeight,
                                      decoration: BoxDecoration(
                                        color: AppPalette.surfacePanel
                                            .withValues(alpha: 0.35),
                                        border: Border.all(color: borderColor),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Expanded(
                                            child: Opacity(
                                              opacity:
                                                  gif.isRemote &&
                                                      !gif.remoteEnabled
                                                  ? 0.4
                                                  : 1.0,
                                              child: _buildGifPreview(gif),
                                            ),
                                          ),
                                          Container(
                                            color: AppPalette.surfacePanel
                                                .withValues(alpha: 0.78),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 6,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  gif.filename,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color:
                                                        colorScheme.onSurface,
                                                    fontWeight: FontWeight.bold,
                                                    decoration:
                                                        gif.isRemote &&
                                                            !gif.remoteEnabled
                                                        ? TextDecoration
                                                              .lineThrough
                                                        : TextDecoration.none,
                                                  ),
                                                ),
                                                if (gif.remoteSize != null)
                                                  Text(
                                                    _formatBytes(
                                                      gif.remoteSize!,
                                                    ),
                                                    style: const TextStyle(
                                                      color: Colors.white70,
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ],
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
                                          color: AppPalette.overlayScrim,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          _stateLabel(gif),
                                          style: TextStyle(
                                            color: borderColor,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                    if ((!_isOffline || _isDemoMode) &&
                                        gif.isRemote)
                                      Positioned(
                                        top: 4,
                                        right: 4,
                                        child: GestureDetector(
                                          onTap: () => _toggleRemoteGif(gif),
                                          child: Container(
                                            padding: const EdgeInsets.all(4),
                                            decoration: BoxDecoration(
                                              color: AppPalette.overlayScrim,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Icon(
                                              gif.remoteEnabled
                                                  ? Icons.visibility
                                                  : Icons.visibility_off,
                                              color: AppPalette.brandAccent,
                                              size: 16,
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (gif.isLocal)
                                      Positioned(
                                        right: 4,
                                        bottom: 42,
                                        child: GestureDetector(
                                          onTap: () =>
                                              _confirmDeleteLocalGif(gif),
                                          child: Container(
                                            padding: const EdgeInsets.all(4),
                                            decoration: BoxDecoration(
                                              color: AppPalette.overlayScrim,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: const Icon(
                                              Icons.delete,
                                              color: AppPalette.statusDanger,
                                              size: 16,
                                            ),
                                          ),
                                        ),
                                      ),
                                    if ((!_isOffline || _isDemoMode) &&
                                        !gif.isLocal &&
                                        gif.isRemote)
                                      Positioned(
                                        right: 4,
                                        bottom: 42,
                                        child: GestureDetector(
                                          onTap: () => _importRemoteGif(gif),
                                          child: Container(
                                            padding: const EdgeInsets.all(4),
                                            decoration: BoxDecoration(
                                              color: AppPalette.overlayScrim,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: const Icon(
                                              Icons.download,
                                              color: AppPalette.brandAccent,
                                              size: 16,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
