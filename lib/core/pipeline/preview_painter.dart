/// 编辑器预览 painter：屏幕画布直绘（源位图 drawImage + 矢量叠加）。
///
/// 不生成中间位图（绕开离屏合成在各后端的显示问题），
/// 滑杆/标注实时无位图分配；导出仍走离屏管线精确合成。
/// 几何变换与导出管线（render.dart）逐节点同构：画布变换按节点逆序
/// 施加各节点的「正向内容映射」，源图以原生尺寸绘制，避免绕旧中心
/// 旋转/拉伸导致的错位。马赛克预览以半透明块近似（导出为精确像素化）。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'node.dart';
import 'render.dart';

/// 一个几何节点的作用前帧 (ow, oh) 与作用后帧 (nw, nh)。
class _GeoStep {
  _GeoStep(this.node, this.ow, this.oh, this.nw, this.nh);

  final FilterNode node;
  final double ow, oh, nw, nh;
}

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

    // 前向记录每个几何节点的作用前/后帧尺寸（逆序施加变换时需要）。
    final steps = <_GeoStep>[];
    var cw = source.width.toDouble(), ch = source.height.toDouble();
    for (final n in nodes) {
      final (double, double)? next = switch (n.op) {
        Ops.rotate =>
          _rotatedSize(cw, ch, (n.params['deg'] as num).toInt()),
        Ops.freeRotate =>
          _freeRotatedSize(cw, ch, (n.params['deg'] as num).toDouble()),
        Ops.flip => (cw, ch),
        Ops.crop => (
            cw * (n.params['w'] as num).toDouble(),
            ch * (n.params['h'] as num).toDouble(),
          ),
        Ops.resize => _resizedSize(n, cw, ch),
        _ => null, // 非几何节点不产生变换
      };
      if (next == null) continue;
      steps.add(_GeoStep(n, cw, ch, next.$1, next.$2));
      (cw, ch) = next;
    }

    canvas.save();
    canvas.translate(off.dx, off.dy);
    canvas.scale(fit);

    // 画布变换为 post-concat（最后调用者先作用于坐标）：按节点逆序
    // 调用各节点的正向内容映射，源点即依栈序流经全部变换。
    for (var i = steps.length - 1; i >= 0; i--) {
      final s = steps[i];
      final n = s.node;
      switch (n.op) {
        case Ops.rotate:
          final d =
              ((n.params['deg'] as num).toInt() % 360 + 360) % 360;
          switch (d) {
            case 90:
              canvas.translate(s.oh, 0);
              canvas.rotate(math.pi / 2);
            case 180:
              canvas.translate(s.ow, s.oh);
              canvas.rotate(math.pi);
            case 270:
              canvas.translate(0, s.ow);
              canvas.rotate(3 * math.pi / 2);
          }
        case Ops.freeRotate:
          final rad = (n.params['deg'] as num).toDouble() * math.pi / 180;
          canvas.translate(s.nw / 2, s.nh / 2);
          canvas.rotate(rad);
          canvas.translate(-s.ow / 2, -s.oh / 2);
        case Ops.flip:
          if ((n.params['axis'] as String) == 'h') {
            canvas.translate(s.ow, 0);
            canvas.scale(-1, 1);
          } else {
            canvas.translate(0, s.oh);
            canvas.scale(1, -1);
          }
        case Ops.crop:
          final rw = (n.params['w'] as num).toDouble();
          final rh = (n.params['h'] as num).toDouble();
          canvas.scale(1 / rw, 1 / rh);
          canvas.translate(
              -(n.params['x'] as num).toDouble() * s.ow,
              -(n.params['y'] as num).toDouble() * s.oh);
        case Ops.resize:
          canvas.scale(s.nw / s.ow, s.nh / s.oh);
      }
    }

    // 源图以原生尺寸绘制：几何以内容映射表达，无目标矩形拉伸
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
    canvas.drawImage(source, ui.Offset.zero, paint);
    canvas.restore(); // 撤几何变换，回到输出画布坐标系

    // 标注矢量叠加（相对比例 × 输出画布）。新标注总是入栈尾、
    // 以最终帧为参照；「先标注后几何」的旧栈序与导出存在既有差异。
    for (final n in nodes) {
      if (n.op == Ops.annotate) {
        paintAnnotateVectors(
            canvas, ui.Size(out.w.toDouble(), out.h.toDouble()), n.params);
      }
    }
  }

  @override
  bool shouldRepaint(covariant EditorPreviewPainter old) =>
      old.generation != generation;
}

/// 90° 倍数旋转的帧尺寸：90/270 交换，180/0 不交换。
(double, double) _rotatedSize(double w, double h, int deg) {
  final d = ((deg % 360) + 360) % 360;
  return (d == 90 || d == 270) ? (h, w) : (w, h);
}

/// 任意角度旋转的包围盒帧尺寸。
(double, double) _freeRotatedSize(double w, double h, double deg) {
  final rad = deg * math.pi / 180;
  final cos = math.cos(rad).abs(), sin = math.sin(rad).abs();
  return (w * cos + h * sin, w * sin + h * cos);
}

/// resize 节点的目标帧尺寸。
(double, double) _resizedSize(FilterNode n, double w, double h) {
  final t = sizeAfter([n], w.round(), h.round());
  return (t.w.toDouble(), t.h.toDouble());
}
