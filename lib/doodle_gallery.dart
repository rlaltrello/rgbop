import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'doodle_editor.dart';
import 'package:http/http.dart' as http;

// Unified model to handle both local and remote files
class DoodleItem {
  final String filename;
  final bool isLocal;
  final File? localFile;
  final List<Color>? pixels;

  DoodleItem({
    required this.filename,
    required this.isLocal,
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
  List<DoodleItem> _doodles = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAllDoodles();
  }

Future<void> _loadAllDoodles() async {
  setState(() => _isLoading = true);
  Map<String, DoodleItem> doodleMap = {};

  // 1. Load Local
  final dir = await getApplicationDocumentsDirectory();
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.bin'));
  
  for (var file in files) {
    String name = file.path.split('/').last;
    doodleMap[name] = DoodleItem(
      filename: name,
      isLocal: true,
      localFile: file,
      pixels: _parseRGB565(await file.readAsBytes()),
    );
  }

  // 2. Load Remote
  final response = await http.get(Uri.parse('http://rgbop.local/api/doodle/list'));
  if (response.statusCode == 200) {
    List<dynamic> remoteFiles = jsonDecode(response.body);
    
    for (var name in remoteFiles) {
      String remoteName = name.toString();

      if (doodleMap.containsKey(remoteName)) {
        // If it exists, update the existing object to reflect it's also remote
        var existing = doodleMap[remoteName]!;
        doodleMap[remoteName] = DoodleItem(
          filename: remoteName,
          isLocal: true,
          localFile: existing.localFile,
          pixels: existing.pixels,
        );
      } else {
        // Add new remote
        final thumb = await http.get(Uri.parse('http://rgbop.local/api/doodle/download?name=$remoteName'));
        doodleMap[remoteName] = DoodleItem(
          filename: remoteName,
          isLocal: false,
          pixels: (thumb.statusCode == 200) ? _parseRGB565(thumb.bodyBytes) : null,
        );
      }
    }
  }

  setState(() {
    _doodles = doodleMap.values.toList();
    _isLoading = false;
  });
}
  List<Color> _parseRGB565(List<int> bytes) {
    List<Color> pixels = [];
    for (int i = 0; i < bytes.length; i += 2) {
      int rgb565 = (bytes[i] << 8) | bytes[i + 1];
      int r = (((rgb565 >> 11) & 0x1F) * 255) ~/ 31;
      int g = (((rgb565 >> 5) & 0x3F) * 255) ~/ 63;
      int b = ((rgb565 & 0x1F) * 255) ~/ 31;
      pixels.add(Color.fromARGB(255, r, g, b));
    }
    return pixels;
  }

Future<void> _confirmDeleteDoodle(DoodleItem doodle) async {
  bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text("Delete Doodle?", style: TextStyle(color: Colors.white)),
      content: const Text("Permanently remove from device and panel?", style: TextStyle(color: Colors.white70)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Delete", style: TextStyle(color: Colors.red))),
      ],
    ),
  );

  if (confirmed == true) {
    // 1. Optimistic UI update: Remove from local list immediately
    setState(() {
      _doodles.removeWhere((item) => item.filename == doodle.filename);
    });

    // 2. Perform local file deletion
    if (doodle.isLocal && doodle.localFile != null && await doodle.localFile!.exists()) {
      await doodle.localFile!.delete();
    }
    
    // 3. Perform remote deletion
    try {
      await http.post(Uri.parse('http://rgbop.local/api/doodle/delete?name=${Uri.encodeComponent(doodle.filename)}'));
    } catch (e) {
      debugPrint("Remote delete failed: $e");
    }
    
    // 4. Final sync: Refresh the list from the server to ensure consistency
    await Future.delayed(const Duration(milliseconds: 500)); // Brief pause for ESP32 FS
    _loadAllDoodles();
  }
}
  Future<void> _confirmClearRemoteDoodles() async {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text("Clear All Doodles?", style: TextStyle(color: Colors.redAccent)),
        content: const Text("Permanently delete all from panel?", style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
          TextButton(onPressed: () {
            Navigator.of(context).pop();
            _clearAllRemoteDoodles();
          }, child: const Text("Yes, Delete All", style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
  }

  Future<void> _clearAllRemoteDoodles() async {
    try {
      final response = await http.post(Uri.parse('http://rgbop.local/api/doodle/clear'));
      if (response.statusCode == 200) _loadAllDoodles();
    } catch (e) {
      debugPrint("Error clearing remote: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('My Doodles'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadAllDoodles),
          IconButton(icon: const Icon(Icons.delete_sweep), onPressed: _confirmClearRemoteDoodles),
          IconButton(icon: const Icon(Icons.add), onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const DoodleEditor()));
            _loadAllDoodles();
          }),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
              itemCount: _doodles.length,
itemBuilder: (context, index) {
  final doodle = _doodles[index];
  
  return GestureDetector(
    onTap: () async {
      final navigator = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);
      List<Color> pixelsToEdit;
      File? fileToEdit;

      if (doodle.isLocal) {
        pixelsToEdit = doodle.pixels!;
        fileToEdit = doodle.localFile;
      } else {
        final response = await http.get(Uri.parse('http://rgbop.local/api/doodle/download?name=${doodle.filename}'));
        if (!mounted) return;
        if (response.statusCode == 200) {
          pixelsToEdit = _parseRGB565(response.bodyBytes);
          final dir = await getApplicationDocumentsDirectory();
          fileToEdit = File('${dir.path}/${doodle.filename}');
          await fileToEdit.writeAsBytes(response.bodyBytes);
        } else {
          messenger.showSnackBar(const SnackBar(content: Text('Failed to download')));
          return;
        }
      }

      await navigator.push(MaterialPageRoute(builder: (_) => DoodleEditor(
        existingFile: fileToEdit,
        initialPixels: pixelsToEdit,
      )));
      _loadAllDoodles();
    },
    // Use LayoutBuilder to force children to know the exact size of the grid cell
    child: LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            // Thumbnail container
            Container(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              decoration: BoxDecoration(border: Border.all(color: doodle.isLocal ? Colors.green : Colors.blue)),
              child: doodle.pixels != null
                  ? CustomPaint(painter: PixelGridPainter(doodle.pixels!, 64, false, Offset.zero))
                  : const Center(child: Icon(Icons.cloud_download, color: Colors.blue)),
            ),
            // Delete Button
            Positioned(
              right: 4, bottom: 4,
              child: GestureDetector(
                onTap: () => _confirmDeleteDoodle(doodle),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                  child: const Icon(Icons.delete, color: Colors.redAccent, size: 16),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
},            ),
    );
  }
}