import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'panel_storage_info.dart';

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
  final String panelIp;

  const GifManagerScreen({super.key, required this.panelIp});

  @override
  State<GifManagerScreen> createState() => _GifManagerScreenState();
}

class _GifManagerScreenState extends State<GifManagerScreen> {
  static const int _expectedGifWidth = 64;
  static const int _expectedGifHeight = 64;
  static const double _snackBarLaneHeight = 76;

  List<GifItem> _gifs = [];
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
    _loadAllGifs();
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    super.dispose();
  }

  String get _baseUrl => 'http://${widget.panelIp}';

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

    final itemsByName = <String, GifItem>{};
    final gifDir = await _localGifDirectory();
    final localFiles = gifDir.listSync().whereType<File>().where(
      (file) => file.path.toLowerCase().endsWith('.gif'),
    );

    for (final file in localFiles) {
      final name = file.path.split('/').last;
      itemsByName[name] = GifItem(
        filename: name,
        isLocal: true,
        isRemote: false,
        localFile: file,
      );
    }

    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/gifs'))
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final remoteGifs = decoded is Map<String, dynamic>
            ? decoded['gifs'] as List<dynamic>? ?? const []
            : const [];

        for (final entry in remoteGifs) {
          if (entry is! Map) continue;

          final filename = entry['name']?.toString();
          if (filename == null || filename.isEmpty) continue;

          final existing = itemsByName[filename];
          itemsByName[filename] = GifItem(
            filename: filename,
            isLocal: existing?.isLocal ?? false,
            isRemote: true,
            localFile: existing?.localFile,
            remoteSize: _parseRemoteSize(entry['size']),
            remoteEnabled: entry['enabled'] != false,
          );
        }
      }
    } catch (_) {
      // Keep local-first workflows available even when the panel is offline.
    }

    final storageInfo = await _fetchStorageInfo(_baseUrl);

    final gifs = itemsByName.values.toList()
      ..sort(
        (a, b) => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()),
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

  Future<void> _addLocalGif() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['gif'],
    );

    final sourcePath = result?.files.single.path;
    if (sourcePath == null) return;

    final dimensions = await _readGifDimensions(sourcePath);
    if (dimensions == null) {
      _showSnack('Could not read GIF dimensions.');
      return;
    }

    if (dimensions.width != _expectedGifWidth ||
        dimensions.height != _expectedGifHeight) {
      _showSnack(
        'GIF must be ${_expectedGifWidth}x$_expectedGifHeight. Selected file is '
        '${dimensions.width.toInt()}x${dimensions.height.toInt()}.',
      );
      return;
    }

    try {
      final gifDir = await _localGifDirectory();
      final sourceFile = File(sourcePath);
      final filename = sourcePath.split('/').last;
      final destination = File('${gifDir.path}/$filename');
      await sourceFile.copy(destination.path);
      _showSnack('Saved $filename to local GIF storage.');
      await _loadAllGifs();
    } catch (e) {
      _showSnack('Failed to save GIF locally: $e');
    }
  }

  Future<Size?> _readGifDimensions(String path) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 10) return null;

    final signature = String.fromCharCodes(bytes.sublist(0, 6));
    if (signature != 'GIF87a' && signature != 'GIF89a') return null;

    final width = bytes[6] | (bytes[7] << 8);
    final height = bytes[8] | (bytes[9] << 8);
    return Size(width.toDouble(), height.toDouble());
  }

  Future<void> _confirmDeleteLocalGif(GifItem gif) async {
    if (!gif.isLocal) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Delete Local GIF?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This removes it from local storage only. The panel copy remains until you press SYNC.',
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
      if (gif.localFile != null && await gif.localFile!.exists()) {
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

    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/gifs/${Uri.encodeComponent(gif.filename)}'))
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

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/gifs/toggle'),
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Sync Local GIFs?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This will clear GIFs on the panel, then upload all local GIFs from this app.',
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
      final gifDir = await _localGifDirectory();
      final localFiles = gifDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.gif'))
          .toList();

      setState(() => _syncStatus = 'Clearing panel GIFs...');
      final clearResponse = await http
          .post(Uri.parse('$_baseUrl/api/gifs/clear'))
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
            Uri.parse('$_baseUrl/api/gifs/upload'),
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

  Widget _buildGifPreview(GifItem gif) {
    final image = gif.isLocal && gif.localFile != null
        ? Image.file(
            gif.localFile!,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.broken_image, color: Colors.grey, size: 32),
          )
        : Image.network(
            '$_baseUrl/gifs/${Uri.encodeComponent(gif.filename)}',
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.broken_image, color: Colors.grey, size: 32),
          );

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: ColoredBox(
        color: const Color(0xFF111111),
        child: Center(child: image),
      ),
    );
  }

  Color _borderColor(GifItem gif) {
    if (gif.isLocal && gif.isRemote) return Colors.amber;
    if (gif.isLocal) return Colors.green;
    return Colors.blue;
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
          border: Border.all(color: Colors.blueAccent),
          color: const Color(0xFF151515),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.add_box_outlined, color: Colors.blueAccent, size: 42),
            SizedBox(height: 10),
            Text(
              'Add GIF',
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
        title: const Text('My GIFs'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadAllGifs),
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: _isSyncing ? null : _syncLocalToPanel,
            tooltip: 'Sync local GIFs to panel',
          ),
          IconButton(icon: const Icon(Icons.add), onPressed: _addLocalGif),
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
                if (_storageInfo != null)
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
                                            color: const Color(0xCC111111),
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
                                                    color: Colors.white,
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
                                          color: Colors.black54,
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
                                    if (gif.isRemote)
                                      Positioned(
                                        top: 4,
                                        right: 4,
                                        child: GestureDetector(
                                          onTap: () => _toggleRemoteGif(gif),
                                          child: Container(
                                            padding: const EdgeInsets.all(4),
                                            decoration: BoxDecoration(
                                              color: Colors.black54,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Icon(
                                              gif.remoteEnabled
                                                  ? Icons.visibility
                                                  : Icons.visibility_off,
                                              color: Colors.blueAccent,
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
                                    if (!gif.isLocal && gif.isRemote)
                                      Positioned(
                                        right: 4,
                                        bottom: 42,
                                        child: GestureDetector(
                                          onTap: () => _importRemoteGif(gif),
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
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
