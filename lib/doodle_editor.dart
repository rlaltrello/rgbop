import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'dart:typed_data';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

class DoodleEditor extends StatefulWidget {
  final int gridSize = 64;
  final File? existingFile;     // NEW: Track if we are editing an existing file
  final List<Color>? initialPixels; // NEW: The loaded image

  const DoodleEditor({super.key, this.existingFile, this.initialPixels});

  @override
  State<DoodleEditor> createState() => _DoodleEditorState();
}

class _DoodleEditorState extends State<DoodleEditor> {
  late List<Color> _pixels;
  Color _selectedColor = Colors.red;

  @override
  void initState() {
    super.initState();
    // NEW: Load initial pixels if provided, otherwise blank canvas
    if (widget.initialPixels != null && widget.initialPixels!.length == widget.gridSize * widget.gridSize) {
      _pixels = List.from(widget.initialPixels!);
    } else {
      _pixels = List.filled(widget.gridSize * widget.gridSize, Colors.black);
    }
  }

  Uint8List _convertToRGB565() {
  final bytes = Uint8List(_pixels.length * 2);
  
  for (int i = 0; i < _pixels.length; i++) {
    final color = _pixels[i];
    
// Extract 8-bit color channels using modern floating-point properties
    int r = (color.r * 255.0).round().clamp(0, 255);
    int g = (color.g * 255.0).round().clamp(0, 255);
    int b = (color.b * 255.0).round().clamp(0, 255);
    
    // Compress to 5-bit Red, 6-bit Green, 5-bit Blue
    int r5 = (r >> 3) & 0x1F;
    int g6 = (g >> 2) & 0x3F;
    int b5 = (b >> 3) & 0x1F;
    
    // Combine into a single 16-bit integer
    int rgb565 = (r5 << 11) | (g6 << 5) | b5;
    
    // Write as Big Endian (high byte first)
    // Note: If your panel renders colors weirdly, flip these two lines (Little Endian)
    bytes[i * 2] = (rgb565 >> 8) & 0xFF; 
    bytes[i * 2 + 1] = rgb565 & 0xFF;
  }
  
  return bytes;
}

Future<void> _saveDoodleLocally() async {
    try {
      // NEW: Overwrite the existing file if we opened one, otherwise create new
      late File file;
      if (widget.existingFile != null) {
        file = widget.existingFile!;
      } else {
        final directory = await getApplicationDocumentsDirectory();
        file = File('${directory.path}/doodle_${DateTime.now().millisecondsSinceEpoch}.bin');
      }
      
      final bytes = _convertToRGB565();
      await file.writeAsBytes(bytes);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved locally: ${file.path.split('/').last}')),
        );
      }
    } catch (e) {
      debugPrint('Error saving doodle locally: $e');
    }
  }

Future<void> _syncToESP32() async {
  final String esp32Url = 'http://rgbop.local/api/doodle/upload'; 
  
  try {
    final bytes = _convertToRGB565();
    var request = http.MultipartRequest('POST', Uri.parse(esp32Url));

    // Determine the filename
    String fileName;
    if (widget.existingFile != null) {
      fileName = widget.existingFile!.path.split('/').last;
    } else {
      fileName = 'doodle_${DateTime.now().millisecondsSinceEpoch}.bin';
    }

    request.files.add(http.MultipartFile.fromBytes(
      'file', 
      bytes, 
      filename: fileName
    ));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (mounted) {
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Synced: $fileName')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to sync: HTTP ${response.statusCode}')),
        );
      }
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Network error: $e')),
      );
    }
  }
}

  void _handleDrawing(Offset localPosition, Size canvasSize) {
    final double pixelWidth = canvasSize.width / widget.gridSize;
    final double pixelHeight = canvasSize.height / widget.gridSize;

    final int x = (localPosition.dx / pixelWidth).floor();
    final int y = (localPosition.dy / pixelHeight).floor();

    if (x >= 0 && x < widget.gridSize && y >= 0 && y < widget.gridSize) {
      final int index = y * widget.gridSize + x;
      if (_pixels[index] != _selectedColor) {
        setState(() {
          _pixels[index] = _selectedColor;
        });
      }
    }
  }

  // --- Color Picker Dialog ---
  void _openColorPicker() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Pick a color'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: _selectedColor,
              onColorChanged: (Color color) {
                setState(() => _selectedColor = color);
              },
              // Alpha is useless on an LED matrix, so we disable it to ensure 
              // we only get solid RGB values for our 565 conversion later.
              enableAlpha: false,
              pickerAreaHeightPercent: 0.8,
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Done'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900], // Dark mode helps visualize matrix
      appBar: AppBar(
        title: const Text('Doodle Editor'),
        actions: [
IconButton(
  icon: const Icon(Icons.save),
  tooltip: 'Save Local',
  onPressed: _saveDoodleLocally,
),
IconButton(
  icon: const Icon(Icons.sync),
  tooltip: 'Sync to ESP32',
  onPressed: _syncToESP32,
)
        ],
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // The Emulated Panel
          Center(
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white24, width: 2),
                color: Colors.black,
              ),
              child: GestureDetector(
                onPanUpdate: (details) => _handleDrawing(details.localPosition, const Size(320, 320)),
                onPanDown: (details) => _handleDrawing(details.localPosition, const Size(320, 320)),
                child: CustomPaint(
                  painter: PixelGridPainter(_pixels, widget.gridSize),
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 40),
          
          // Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            margin: const EdgeInsets.symmetric(horizontal: 32),
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                // Color Picker Button
                GestureDetector(
                  onTap: _openColorPicker,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _selectedColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [
                        BoxShadow(
                          color: _selectedColor.withValues(alpha: 0.5),
                          blurRadius: 8,
                          spreadRadius: 2,
                        )
                      ],
                    ),
                  ),
                ),
                
                // Eraser (Sets brush to black)
                IconButton(
                  icon: const Icon(Icons.cleaning_services, color: Colors.white70),
                  tooltip: 'Eraser',
                  onPressed: () {
                    setState(() {
                      _selectedColor = Colors.black;
                    });
                  },
                ),

                // Clear Canvas
                IconButton(
                  icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
                  tooltip: 'Clear Canvas',
                  onPressed: () {
                    setState(() {
                      _pixels = List.filled(widget.gridSize * widget.gridSize, Colors.black);
                    });
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PixelGridPainter extends CustomPainter {
  final List<Color> pixels;
  final int gridSize;

  PixelGridPainter(this.pixels, this.gridSize);

  @override
  void paint(Canvas canvas, Size size) {
    final double cellWidth = size.width / gridSize;
    final double cellHeight = size.height / gridSize;
    final Paint paint = Paint()..style = PaintingStyle.fill;

    for (int y = 0; y < gridSize; y++) {
      for (int x = 0; x < gridSize; x++) {
        final int index = y * gridSize + x;
        paint.color = pixels[index];
        
        // Draw each pixel as a small rectangle on the canvas
        canvas.drawRect(
          Rect.fromLTWH(x * cellWidth, y * cellHeight, cellWidth, cellHeight),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant PixelGridPainter oldDelegate) {
    // For better performance, you'd want a more granular check, 
    // but this works for a 64x64 grid.
    return true; 
  }
}