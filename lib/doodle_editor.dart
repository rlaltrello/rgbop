import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'dart:typed_data';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

class DoodleEditor extends StatefulWidget {
  final int gridSize = 64;
  final File? existingFile;
  final List<Color>? initialPixels;

  const DoodleEditor({super.key, this.existingFile, this.initialPixels});

  @override
  State<DoodleEditor> createState() => _DoodleEditorState();
}

class _DoodleEditorState extends State<DoodleEditor> {
  late List<Color> _pixels;
  Color _selectedColor = Colors.red;
  
  // Mutable state variable to track the active file instead of using widget.existingFile
  File? _currentFile;
  
  bool _isZoomMode = false;
  bool _isFillMode = false; 
  bool _isDraggingBox = false;
  int _brushSize = 1; // Tracks brush thickness (1px, 2px, 3px)
  bool _isEyedropperMode = false;
  Offset _zoomOffset = const Offset(27.0, 27.0); 
  final List<List<Color>> _undoHistory = [];
  final int _maxHistory = 50; // Prevent infinite memory growth

  @override
  void initState() {
    super.initState();
    // Initialize our mutable state variable with the passed file from the parent widget
    _currentFile = widget.existingFile;
    
    _pixels = widget.initialPixels != null && widget.initialPixels!.length == widget.gridSize * widget.gridSize
        ? List.from(widget.initialPixels!)
        : List.filled(widget.gridSize * widget.gridSize, Colors.black);
  }

  // --- Conversions & Sync ---
  Uint8List _convertToRGB565() {
    final bytes = Uint8List(_pixels.length * 2);
    for (int i = 0; i < _pixels.length; i++) {
      int r = (_pixels[i].r * 255.0).round().clamp(0, 255);
      int g = (_pixels[i].g * 255.0).round().clamp(0, 255);
      int b = (_pixels[i].b * 255.0).round().clamp(0, 255);
      int rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
      bytes[i * 2] = (rgb565 >> 8) & 0xFF;
      bytes[i * 2 + 1] = rgb565 & 0xFF;
    }
    return bytes;
  }

  Future<void> _saveDoodleLocally() async {
    try {
      if (_currentFile == null) {
        final directory = await getApplicationDocumentsDirectory();
        // Create and assign the new file object safely inside state
        _currentFile = File('${directory.path}/doodle_${DateTime.now().millisecondsSinceEpoch}.bin');
      }
      
      await _currentFile!.writeAsBytes(_convertToRGB565());
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved locally: ${_currentFile!.path.split('/').last}'))
        );
      }
      // Rebuild UI so we now reference the new local file
      setState(() {}); 
    } catch (e) {
      debugPrint('Error saving doodle locally: $e');
    }
  }

  Future<void> _syncToESP32() async {
    // 1. If it's not saved locally yet, save it first so we establish a consistent filename
    if (_currentFile == null) {
      await _saveDoodleLocally();
    }

    final String esp32Url = 'http://rgbop.local/api/doodle/upload';
    try {
      final bytes = _convertToRGB565();
      var request = http.MultipartRequest('POST', Uri.parse(esp32Url));
      
      // Ensure we consistently use the exact same filename
      String fileName = _currentFile!.path.split('/').last;
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: fileName));
      
      final response = await http.Response.fromStream(await request.send());
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(response.statusCode == 200 ? 'Synced: $fileName' : 'Failed: ${response.statusCode}'))
        );
      }
    } catch (e) {
      debugPrint('Network error: $e');
    }
  }

  // --- Flood Fill Algorithm ---
  void _floodFill(int x, int y) {
    int startIndex = y * widget.gridSize + x;
    Color targetColor = _pixels[startIndex];
    Color replacementColor = _selectedColor;

    if (targetColor.toARGB32() == replacementColor.toARGB32()) return;

    List<int> stack = [startIndex];

    while (stack.isNotEmpty) {
      int current = stack.removeLast();
      
      if (_pixels[current].toARGB32() == targetColor.toARGB32()) {
        _pixels[current] = replacementColor;

        int cx = current % widget.gridSize;
        int cy = current ~/ widget.gridSize;

        if (cx > 0) stack.add(current - 1); 
        if (cx < widget.gridSize - 1) stack.add(current + 1); 
        if (cy > 0) stack.add(current - widget.gridSize); 
        if (cy < widget.gridSize - 1) stack.add(current + widget.gridSize); 
      }
    }
    setState(() {});
  }

  // --- Brush Application Logic ---
  void _applyBrush(int cx, int cy) {
    int offset = _brushSize == 3 ? 1 : 0;
    bool changed = false;

    for (int i = 0; i < _brushSize; i++) {
      for (int j = 0; j < _brushSize; j++) {
        int px = cx + i - offset;
        int py = cy + j - offset;
        
        if (px >= 0 && px < widget.gridSize && py >= 0 && py < widget.gridSize) {
          int index = py * widget.gridSize + px;
          if (_pixels[index].toARGB32() != _selectedColor.toARGB32()) {
            _pixels[index] = _selectedColor;
            changed = true;
          }
        }
      }
    }
    if (changed) setState(() {});
  }

  void _saveToHistory() {
    _undoHistory.add(List.from(_pixels)); 
    if (_undoHistory.length > _maxHistory) {
      _undoHistory.removeAt(0); 
    }
    setState(() {}); 
  }

  void _undo() {
    if (_undoHistory.isNotEmpty) {
      setState(() {
        _pixels = _undoHistory.removeLast();
      });
    }
  }

  // --- Main Canvas Drawing ---
  void _handleMainDrawing(Offset localPosition, Size canvasSize, {bool isTap = false}) {
    final double cell = canvasSize.width / widget.gridSize;
    int x = (localPosition.dx / cell).floor();
    int y = (localPosition.dy / cell).floor();
    
    if (x >= 0 && x < widget.gridSize && y >= 0 && y < widget.gridSize) {
      if (_isEyedropperMode) {
        if (_pixels[y * widget.gridSize + x].toARGB32() != _selectedColor.toARGB32()) {
          setState(() => _selectedColor = _pixels[y * widget.gridSize + x]);
        }
        return;
      }

      if (_isFillMode) {
        if (isTap) _floodFill(x, y);
      } else {
        _applyBrush(x, y);
      }
    }
  }

  // --- Zoom Window Drawing ---
  void _handleZoomDrawing(Offset localPosition, double zoomWindowSize, {bool isTap = false}) {
    final double cell = zoomWindowSize / 10;
    int localX = (localPosition.dx / cell).floor();
    int localY = (localPosition.dy / cell).floor();

    if (localX >= 0 && localX < 10 && localY >= 0 && localY < 10) {
      int mainX = _zoomOffset.dx.toInt() + localX;
      int mainY = _zoomOffset.dy.toInt() + localY;
      
      if (mainX >= 0 && mainX < widget.gridSize && mainY >= 0 && mainY < widget.gridSize) {
        if (_isEyedropperMode) {
          int index = mainY * widget.gridSize + mainX;
          if (_pixels[index].toARGB32() != _selectedColor.toARGB32()) {
            setState(() => _selectedColor = _pixels[index]);
          }
          return;
        }

        if (_isFillMode) {
          if (isTap) _floodFill(mainX, mainY);
        } else {
          _applyBrush(mainX, mainY);
        }
      }
    }
  }

  // --- Zoom Box Dragging ---
  void _updateZoomBoxPosition(Offset delta, Size canvasSize) {
    double s = canvasSize.width / widget.gridSize;
    setState(() {
      double newX = _zoomOffset.dx + (delta.dx / s);
      double newY = _zoomOffset.dy + (delta.dy / s);
      newX = newX.clamp(0.0, widget.gridSize - 10.0);
      newY = newY.clamp(0.0, widget.gridSize - 10.0);
      _zoomOffset = Offset(newX, newY);
    });
  }

  void _openColorPicker() {
    showDialog(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Pick a color'),
        content: SingleChildScrollView(child: ColorPicker(pickerColor: _selectedColor, onColorChanged: (c) => setState(() => _selectedColor = c), enableAlpha: false)),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const Size canvasSize = Size(320, 320);
    const double zoomWindowSize = 250.0;

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(title: const Text('Doodle Editor'), actions: [
        IconButton(
          icon: const Icon(Icons.undo), 
          tooltip: 'Undo',
          onPressed: _undoHistory.isNotEmpty ? _undo : null, 
        ),
        IconButton(icon: const Icon(Icons.save), onPressed: _saveDoodleLocally),
        IconButton(icon: const Icon(Icons.sync), onPressed: _syncToESP32),
      ]),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_isZoomMode)
                  GestureDetector(
                    onPanStart: (d) {
                      if (!_isEyedropperMode) _saveToHistory(); 
                      _handleZoomDrawing(d.localPosition, zoomWindowSize, isTap: true);
                    },
                    onPanUpdate: (d) => _handleZoomDrawing(d.localPosition, zoomWindowSize, isTap: false),
                    onPanEnd: (_) {
                      if (_isEyedropperMode) setState(() => _isEyedropperMode = false); 
                    },
                    child: Container(
                      width: zoomWindowSize, height: zoomWindowSize, 
                      decoration: BoxDecoration(
                        color: Colors.black, 
                        border: Border.all(color: Colors.white70, width: 3),
                        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10, spreadRadius: 5)],
                      ),
                      child: CustomPaint(painter: ZoomedPainter(_pixels, _zoomOffset)),
                    ),
                  )
                else
                  const SizedBox(height: zoomWindowSize),

                const SizedBox(height: 24),

                GestureDetector(
                  onPanStart: (details) {
                    if (_isZoomMode) {
                      _isDraggingBox = true;
                    } else {
                      if (!_isEyedropperMode) _saveToHistory();
                      _handleMainDrawing(details.localPosition, canvasSize, isTap: true);
                    }
                  },
                  onPanUpdate: (details) {
                    if (_isZoomMode) {
                      if (_isDraggingBox) {
                        _updateZoomBoxPosition(details.delta, canvasSize);
                      }
                    } else {
                      _handleMainDrawing(details.localPosition, canvasSize, isTap: false);
                    }
                  },
                  onPanEnd: (_) {
                    _isDraggingBox = false;
                    if (_isEyedropperMode) setState(() => _isEyedropperMode = false);
                  },
                  child: Container(
                    width: canvasSize.width, height: canvasSize.height,
                    decoration: BoxDecoration(border: Border.all(color: Colors.white24, width: 2), color: Colors.black),
                    child: CustomPaint(painter: PixelGridPainter(_pixels, widget.gridSize, _isZoomMode, _zoomOffset)),
                  ),
                ),

                const SizedBox(height: 32),

                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(16)),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                    GestureDetector(onTap: _openColorPicker, child: CircleAvatar(backgroundColor: _selectedColor, radius: 18)),
                    
                    IconButton(
                      icon: Icon(Icons.format_color_fill, color: _isFillMode ? Colors.blue : Colors.white), 
                      onPressed: () => setState(() => _isFillMode = !_isFillMode),
                      tooltip: 'Flood Fill',
                    ),

                    GestureDetector(
                      onTap: () => setState(() => _brushSize = _brushSize >= 3 ? 1 : _brushSize + 1),
                      child: Container(
                        width: 32, height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white70, width: 2),
                          shape: BoxShape.circle,
                        ),
                        child: Text('${_brushSize}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ),

                    IconButton(
                      icon: Icon(_isZoomMode ? Icons.zoom_out : Icons.zoom_in, color: _isZoomMode ? Colors.blue : Colors.white), 
                      onPressed: () => setState(() {
                        _isZoomMode = !_isZoomMode;
                        _isDraggingBox = false; 
                      }),
                      tooltip: 'Zoom Window',
                    ),
                    IconButton(
                      icon: Icon(Icons.colorize, color: _isEyedropperMode ? Colors.blue : Colors.white), 
                      onPressed: () => setState(() {
                        _isEyedropperMode = !_isEyedropperMode;
                        if (_isEyedropperMode) _isFillMode = false;
                      }),
                      tooltip: 'Eyedropper',
                    ),
                    IconButton(
                      icon: const Icon(Icons.cleaning_services, color: Colors.white70), 
                      onPressed: () => setState(() => _selectedColor = Colors.black),
                      tooltip: 'Eraser',
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_forever, color: Colors.redAccent), 
                      onPressed: () {
                        _saveToHistory();
                        setState(() => _pixels = List.filled(4096, Colors.black));
                      },
                      tooltip: 'Clear All',
                    ),
                  ]),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- Main 64x64 Painter ---
class PixelGridPainter extends CustomPainter {
  final List<Color> pixels;
  final int gridSize;
  final bool isZoomMode;
  final Offset zoomOffset;

  PixelGridPainter(this.pixels, this.gridSize, this.isZoomMode, this.zoomOffset);

  @override
  void paint(Canvas canvas, Size size) {
    double s = size.width / gridSize;
    Paint bg = Paint()..color = Colors.black;
    Paint pix = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < pixels.length; i++) {
      int x = i % gridSize; int y = i ~/ gridSize;
      canvas.drawRect(Rect.fromLTWH(x * s, y * s, s, s), bg);
      if (pixels[i].toARGB32() != Colors.black.toARGB32()) {
        pix.color = pixels[i];
        canvas.drawCircle(Offset(x * s + s/2, y * s + s/2), s * 0.35, pix);
      }
    }
    
    if (isZoomMode) {
      int zx = zoomOffset.dx.toInt();
      int zy = zoomOffset.dy.toInt(); // <--- CORRECTED: Changed 'zy' to 'dy'
      canvas.drawRect(Rect.fromLTWH(zx * s, zy * s, 10 * s, 10 * s), 
        Paint()..color = Colors.blue..style = PaintingStyle.stroke..strokeWidth = 3);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class ZoomedPainter extends CustomPainter {
  final List<Color> pixels;
  final Offset zoomOffset;

  ZoomedPainter(this.pixels, this.zoomOffset);

  @override
  void paint(Canvas canvas, Size size) {
    double s = size.width / 10;
    Paint bg = Paint()..color = Colors.black;
    Paint pix = Paint()..style = PaintingStyle.fill;

    for (int y = 0; y < 10; y++) {
      for (int x = 0; x < 10; x++) {
        int mainX = zoomOffset.dx.toInt() + x;
        int mainY = zoomOffset.dy.toInt() + y;
        
        canvas.drawRect(Rect.fromLTWH(x * s, y * s, s, s), bg);
        
        if (mainX < 64 && mainY < 64) {
          Color c = pixels[mainY * 64 + mainX];
          if (c.toARGB32() != Colors.black.toARGB32()) {
            pix.color = c;
            canvas.drawCircle(Offset(x * s + s/2, y * s + s/2), s * 0.4, pix);
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}