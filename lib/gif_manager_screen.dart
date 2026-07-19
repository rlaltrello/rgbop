import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';

class GifManagerScreen extends StatefulWidget {
  final String panelIp;
  const GifManagerScreen({super.key, required this.panelIp});

  @override
  State<GifManagerScreen> createState() => _GifManagerScreenState();
}

class _GifManagerScreenState extends State<GifManagerScreen> {
  static const int _expectedGifWidth = 64;
  static const int _expectedGifHeight = 64;

  List<dynamic> _gifs = [];
  bool _isLoading = true;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    _fetchGifs();
  }

  Future<void> _fetchGifs() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('http://${widget.panelIp}/api/gifs'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _gifs = data['gifs'] ?? [];
          _isLoading = false;
        });
      }
    } catch (e) {
      _showError("Failed to load GIFs from panel.");
      setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteGif(String filename) async {
    // 1. Optimistic Update: Instantly remove it from the UI!
    setState(() {
      _gifs.removeWhere((g) => g['name'] == filename);
    });

    try {
      // 2. Tell the ESP32 to actually delete the file
      final response = await http.post(
        Uri.parse('http://${widget.panelIp}/api/gifs/delete'),
        body: {'name': filename},
      );

      if (response.statusCode == 200) {
        // Success! We can optionally call _fetchGifs() here just to be strictly
        // in sync, but the item is already gone from the screen.
      } else {
        // 3. Rollback: If the board failed to delete it, show an error and refresh
        _showError("Failed to delete $filename on panel.");
        _fetchGifs();
      }
    } catch (e) {
      _showError("Network error while deleting.");
      _fetchGifs(); // Rollback the UI
    }
  }

  Future<void> _confirmDelete(String filename) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text("Delete GIF?"),
        content: Text("Are you sure you want to permanently delete $filename?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      _deleteGif(filename);
    }
  }

  Future<void> _toggleGif(String filename, bool currentEnabled) async {
    try {
      final response = await http.post(
        Uri.parse('http://${widget.panelIp}/api/gifs/toggle'),
        body: {'name': filename, 'enabled': (!currentEnabled).toString()},
      );
      if (response.statusCode == 200) {
        _fetchGifs(); // Refresh list to get updated names
      } else {
        _showError("Failed to toggle GIF state.");
      }
    } catch (e) {
      _showError("Network error while toggling.");
    }
  }

  Future<void> _uploadGif() async {
    // 1. Open the native OS file picker
    FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['gif'],
    );

    if (result != null && result.files.single.path != null) {
      final dimensions = await _readGifDimensions(result.files.single.path!);
      if (dimensions == null) {
        _showError('Could not read GIF dimensions.');
        return;
      }

      if (dimensions.width != _expectedGifWidth ||
          dimensions.height != _expectedGifHeight) {
        _showError(
          'GIF must be ${_expectedGifWidth}x$_expectedGifHeight. Selected file is '
          '${dimensions.width.toInt()}x${dimensions.height.toInt()}.',
        );
        return;
      }

      setState(() => _isUploading = true);

      try {
        // 2. Build a multipart form request to stream the binary file
        var request = http.MultipartRequest(
          'POST',
          Uri.parse('http://${widget.panelIp}/api/gifs/upload'),
        );
        request.files.add(
          await http.MultipartFile.fromPath('file', result.files.single.path!),
        );

        var response = await request.send();

        if (response.statusCode == 200) {
          _showSuccess("GIF uploaded successfully!");
          await _fetchGifs();
        } else {
          _showError("Upload failed. Storage might be full.");
        }
      } catch (e) {
        _showError("Network error during upload.");
      }

      setState(() => _isUploading = false);
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

  // --- Helper to make byte sizes human-readable ---
  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
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
    return Scaffold(
      appBar: AppBar(
        title: const Text("GIF Manager"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isUploading ? null : _fetchGifs,
          ),
        ],
      ),
      body: Column(
        children: [
          // --- PANEL IP HEADER ---
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0, top: 16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.wifi, color: Colors.grey, size: 16),
                const SizedBox(width: 8),
                Text(
                  "Panel IP = ${widget.panelIp}",
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

          // --- DYNAMIC CONTENT ---
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _gifs.isEmpty
                ? const Center(
                    child: Text(
                      "No GIFs found on panel.",
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(
                      top: 8,
                      left: 16,
                      right: 16,
                      bottom: 100,
                    ),
                    itemCount: _gifs.length,
                    itemBuilder: (context, index) {
                      final gif = _gifs[index];
                      final bool isEnabled = gif['enabled'] ?? true;

                      return Card(
                        color: const Color(0xFF1E1E1E),
                        child: Opacity(
                          opacity: isEnabled
                              ? 1.0
                              : 0.4, // Gray out if disabled
                          child: ListTile(
                            leading: SizedBox(
                              width: 50,
                              height: 50,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  'http://${widget.panelIp}/gifs/${gif['name']}',
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const Icon(
                                        Icons.broken_image,
                                        color: Colors.grey,
                                        size: 32,
                                      ),
                                ),
                              ),
                            ),
                            title: Text(
                              // Clean up the display name for the user
                              gif['name'].toString().replaceAll('_', ''),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                decoration: isEnabled
                                    ? TextDecoration.none
                                    : TextDecoration.lineThrough,
                              ),
                            ),
                            subtitle: Text(_formatBytes(gif['size'])),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(
                                    isEnabled
                                        ? Icons.visibility
                                        : Icons.visibility_off,
                                    color: Colors.blueAccent,
                                  ),
                                  onPressed: () =>
                                      _toggleGif(gif['name'], isEnabled),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.redAccent,
                                  ),
                                  onPressed: () => _confirmDelete(gif['name']),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isUploading ? null : _uploadGif,
        backgroundColor: Colors.blueAccent,
        icon: _isUploading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            : const Icon(Icons.upload_file),
        label: Text(
          _isUploading ? "Uploading..." : "Upload GIF",
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
