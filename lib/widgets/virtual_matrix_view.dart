import 'package:flutter/material.dart';

class VirtualMatrixView extends StatelessWidget {
  final List<Color> pixels;
  final int gridSize;
  final double size;

  const VirtualMatrixView({
    super.key,
    required this.pixels,
    this.gridSize = 64,
    this.size = 220,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(10),
        color: Colors.black,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: CustomPaint(
          painter: _MatrixPainter(
            pixels: pixels,
            gridSize: gridSize,
          ),
        ),
      ),
    );
  }
}

class _MatrixPainter extends CustomPainter {
  final List<Color> pixels;
  final int gridSize;

  _MatrixPainter({
    required this.pixels,
    required this.gridSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pixelPaint = Paint()..style = PaintingStyle.fill;
    final cellW = size.width / gridSize;
    final cellH = size.height / gridSize;

    for (var y = 0; y < gridSize; y++) {
      for (var x = 0; x < gridSize; x++) {
        final idx = y * gridSize + x;
        final color = idx < pixels.length ? pixels[idx] : Colors.black;
        pixelPaint.color = color;
        canvas.drawRect(
          Rect.fromLTWH(x * cellW, y * cellH, cellW, cellH),
          pixelPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MatrixPainter oldDelegate) {
    return oldDelegate.pixels != pixels;
  }
}
