import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'doodle_editor.dart';

class DoodleGallery extends StatefulWidget {
  const DoodleGallery({super.key});

  @override
  State<DoodleGallery> createState() => _DoodleGalleryState();
}

class _DoodleGalleryState extends State<DoodleGallery> {
  List<File> _doodleFiles = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    setState(() => _isLoading = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      // Find all files that end with .bin and contain "doodle"
      final files = dir.listSync().whereType<File>().where((file) => 
        file.path.endsWith('.bin') && file.path.contains('doodle')).toList();
      
      setState(() {
        _doodleFiles = files;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("Error loading files: $e");
      setState(() => _isLoading = false);
    }
  }

  // --- Insert the parseRGB565 helper method here ---
  List<Color> _parseRGB565(List<int> bytes) {
    List<Color> pixels = [];
    for (int i = 0; i < bytes.length; i += 2) {
      int rgb565 = (bytes[i] << 8) | bytes[i + 1]; 
      int r5 = (rgb565 >> 11) & 0x1F;
      int g6 = (rgb565 >> 5) & 0x3F;
      int b5 = rgb565 & 0x1F;
      int r = (r5 * 255) ~/ 31;
      int g = (g6 * 255) ~/ 63;
      int b = (b5 * 255) ~/ 31;
      pixels.add(Color.fromARGB(255, r, g, b));
    }
    return pixels;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('My Doodles'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              // Open a new blank editor
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const DoodleEditor()),
              );
              // Refresh list when returning
              _loadFiles(); 
            },
          )
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : _doodleFiles.isEmpty
          ? const Center(child: Text('No doodles yet. Tap + to create one.', style: TextStyle(color: Colors.white70)))
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, 
                crossAxisSpacing: 16, 
                mainAxisSpacing: 16,
              ),
              itemCount: _doodleFiles.length,
              itemBuilder: (context, index) {
                final file = _doodleFiles[index];
                
                return FutureBuilder<List<int>>(
                  future: file.readAsBytes(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return Container(color: Colors.black26);
                    }
                    
                    // Parse bytes into colors for the thumbnail
                    final pixels = _parseRGB565(snapshot.data!);

                    return GestureDetector(
                      onTap: () async {
                        // Open existing doodle
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => DoodleEditor(
                              existingFile: file,
                              initialPixels: pixels,
                            ),
                          ),
                        );
                        // Refresh when returning in case they saved over it
                        _loadFiles(); 
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white24),
                        ),
                        // Reuse our PixelGridPainter for the thumbnail!
                        child: CustomPaint(
                          painter: PixelGridPainter(pixels, 64),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}