/// 编辑器预览 painter：屏幕画布直绘（源位图 drawImage + 矢量叠加）。
///
/// 不生成中间位图（绕开离屏合成在各后端的显示问题），
/// 滑杆/标注实时无位图分配；导出仍走离屏管线精确合成。
/// 马赛克预览以半透明块近似（导出为精确像素化）。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'node.dart';
import 'render.dart';

class EditorPreviewPainter extends CustomPainter {
  EditorPreviewPainter({
    required this.source,
    required this.nodes,
    required this.generation,
  });

  final ui.Image source;
  final List<FilterNode> nodes;
  final int generation; // 节点/历史代数：变化即重绘

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(
        ui.Offset.zero & size, ui.Paint()..color = const ui.Color(0xFF101216));

    final out = sizeAfter(nodes, source.width, source.height);
    final fit = math.min(size.width / out.w, size.height / out.h);
    final drawW = out.w * fit, drawH = out.h * fit;
    final off = Offset((size.width - drawW) / 2, (size.height - drawH) / 2);

    canvas.save();
    canvas.translate(off.dx, off.dy);
    canvas.scale(fit);

    // 几何变换（正序）：旋转 / 自由旋转 / 翻转 / 裁剪
    var cw = source.width.toDouble(), ch = source.height.toDouble();
    for (final n in nodes) {
      switch (n.op) {
        case Ops.rotate:
          final deg = (n.params['deg'] as num).toInt();
          canvas.translate(cw / 2, ch / 2);
          canvas.rotate(deg * math.pi / 180);
          canvas.translate(-cw / 2, -ch / 2);
          final t = cw;
          cw = ch;
          ch = t;
        case Ops.freeRotate:
          final rad = (n.params['deg'] as num).toDouble() * math.pi / 180;
          final nw = cw * math.cos(rad).abs() + ch * math.sin(rad).abs();
          final nh = cw * math.sin(rad).abs() + ch * math.cos(rad).abs();
          canvas.translate(cw / 2, ch / 2);
          canvas.rotate(rad);
          canvas.translate(-cw / 2, -ch / 2);
          cw = nw;
          ch = nh;
        case Ops.flip:
          final axis = n.params['axis'] as String;
          if (axis == 'h') {
            canvas.translate(cw, 0);
            canvas.scale(-1, 1);
          } else {
            canvas.translate(0, ch);
            canvas.scale(1, -1);
          }
        case Ops.crop:
          final rx = (n.params['x'] as num).toDouble();
          final ry = (n.params['y'] as num).toDouble();
          final rw = (n.params['w'] as num).toDouble();
          final rh = (n.params['h'] as num).toDouble();
          canvas.clipRect(
              ui.Rect.fromLTWH(rx * cw, ry * ch, rw * cw, rh * ch));
          canvas.translate(-rx * cw, -ry * ch);
          cw = rw * cw;
          ch = rh * ch;
      }
    }

    // 颜色调整/滤镜由 widget 层 ColorFiltered 应用（Impeller 下
    // drawImage+ColorFilter 组合不生效），此处只画原始位图
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
    canvas.drawImageRect(
        source,
        ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, cw, ch),
        paint);

    // 标注矢量叠加（相对比例 × 当前逻辑画布）
    for (final n in nodes) {
      if (n.op == Ops.annotate) {
        paintAnnotateVectors(canvas, ui.Size(cw, ch), n.params);
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant EditorPreviewPainter old) =>
      old.generation != generation;
}
