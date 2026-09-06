/// Filter Pipeline 求值引擎：把节点序列渲染为像素（Filter Pipeline 的心脏）。
///
/// 尺寸推演与预设展开是纯函数（可单测）；像素求值依赖 dart:ui。
/// 非破坏性：任何求值都不修改原图，输出全新 ui.Image。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'node.dart';

/// 滤镜预设 = 一组调整参数的组合（设计书 2.3：可在此基础上继续微调）。
Map<String, double> presetExpansion(String name) => switch (name) {
      'bw' => {'saturation': -1.0, 'contrast': 0.15},
      'sepia' => {'saturation': -0.7, 'temperature': 0.5, 'contrast': 0.05},
      'film' => {'contrast': 0.18, 'saturation': -0.12, 'vignette': 0.25},
      'cool' => {'temperature': -0.4, 'saturation': 0.05},
      'warm' => {'temperature': 0.4, 'saturation': 0.08},
      'fade' => {'contrast': -0.15, 'brightness': 0.05, 'saturation': -0.2},
      _ => throw ArgumentError.value(name, 'name', '未知滤镜预设'),
    };

/// 已知预设名（UI 与校验共用）。
const knownPresets = ['bw', 'sepia', 'film', 'cool', 'warm', 'fade'];

/// 求值后输出尺寸（纯逻辑）：crop 缩小、rotate 交换宽高、resize 缩放。
({int w, int h}) sizeAfter(List<FilterNode> nodes, int srcW, int srcH) {
  var (w, h) = (srcW.toDouble(), srcH.toDouble());
  for (final n in nodes) {
    switch (n.op) {
      case Ops.freeRotate:
        final rad = (n.params['deg'] as num).toDouble() * math.pi / 180;
        final cos = math.cos(rad).abs();
        final sin = math.sin(rad).abs();
        final nw = w * cos + h * sin;
        final nh = w * sin + h * cos;
        w = nw;
        h = nh;
      case Ops.rotate:
        // 90/270 交换宽高；180/0 不交换
        final d = ((n.params['deg'] as num).toInt() % 360 + 360) % 360;
        if (d == 90 || d == 270) {
          final t = w;
          w = h;
          h = t;
        }
      case Ops.crop:
        w = w * (n.params['w'] as num);
        h = h * (n.params['h'] as num);
      case Ops.resize:
        final pw = (n.params['width'] as num?)?.toDouble();
        final ph = (n.params['height'] as num?)?.toDouble();
        if (pw != null && h > 0) {
          h = h * (pw / w);
          w = pw;
        } else if (ph != null && w > 0) {
          w = w * (ph / h);
          h = ph;
        }
    }
  }
  return (w: math.max(1, w.round()), h: math.max(1, h.round()));
}

/// 汇总管线中全部 调整/滤镜 节点为合并参数表（屏幕预览用）。
Map<String, double> mergedAdjustOf(List<FilterNode> nodes) {
  final merged = <String, double>{};
  for (final n in nodes) {
    if (n.op == Ops.adjust) {
      n.params.forEach((k, v) =>
          merged[k] = ((merged[k] ?? 0) + (v as num).toDouble())
              .clamp(-1.0, 1.0)
              .toDouble());
    } else if (n.op == Ops.preset) {
      presetExpansion(n.params['name'] as String)
          .forEach((k, v) => merged[k] = v);
    }
  }
  return merged;
}

/// 节点是否需要用户确认才会执行（AI 生成式节点）。
bool nodeNeedsConfirm(FilterNode n) => n.op == Ops.aiEdit;

/// 按序求值节点，返回新图像；调用方负责 dispose 返回值。
Future<ui.Image> renderPipeline(ui.Image source, List<FilterNode> nodes) async {
  var img = source;
  for (final n in nodes) {
    img = await _apply(img, n);
  }
  return img;
}

/// 合成一张新位图。用 toImageSync（GPU 常驻、无回读）——
/// Windows Impeller/OpenGL 后端下 Picture.toImage 存在崩溃问题，
/// 且 toImageSync 省去 GPU→CPU 回读，预览滑杆明显更流畅。
ui.Image newCanvasSync(int w, int h, void Function(ui.Canvas c) draw) {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  draw(c);
  return rec.endRecording().toImageSync(w, h);
}

Future<ui.Image> _newCanvas(int w, int h, void Function(ui.Canvas c) draw) async {
  return newCanvasSync(w, h, draw);
}

Future<ui.Image> _apply(ui.Image img, FilterNode n) async {
  switch (n.op) {
    case Ops.freeRotate:
      final rad = (n.params['deg'] as num).toDouble() * math.pi / 180;
      final cos = math.cos(rad).abs(), sin = math.sin(rad).abs();
      final w = (img.width * cos + img.height * sin).ceil();
      final h = (img.width * sin + img.height * cos).ceil();
      return _newCanvas(w, h, (c) {
        // 背景填充主题底色（旋转露出的角落）
        c.drawRect(
            ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
            ui.Paint()..color = const ui.Color(0xFF14161A));
        c.translate(w / 2, h / 2);
        c.rotate(rad);
        c.drawImage(
            img,
            ui.Offset(-img.width / 2, -img.height / 2),
            ui.Paint()..filterQuality = ui.FilterQuality.medium);
      });

    case Ops.rotate:
      final d = ((n.params['deg'] as num).toInt() % 360 + 360) % 360;
      final swap = d == 90 || d == 270;
      final w = swap ? img.height : img.width;
      final h = swap ? img.width : img.height;
      return _newCanvas(w, h, (c) {
        // 新画布中心为旋转中心：源图绕中心旋转后恰好充满画布
        c.translate(w / 2, h / 2);
        c.rotate(d * math.pi / 180);
        c.drawImage(img, ui.Offset(-img.width / 2, -img.height / 2), ui.Paint());
      });

    case Ops.flip:
      final axis = n.params['axis'] as String;
      return _newCanvas(img.width, img.height, (c) {
        // 先平移再镜像：翻转后恰好铺满画布（先 scale 后 translate 会越出画布）
        if (axis == 'h') {
          c.translate(img.width.toDouble(), 0);
          c.scale(-1, 1);
        } else {
          c.translate(0, img.height.toDouble());
          c.scale(1, -1);
        }
        c.drawImage(img, ui.Offset.zero, ui.Paint());
      });

    case Ops.crop:
      final rx = (n.params['x'] as num).toDouble();
      final ry = (n.params['y'] as num).toDouble();
      final rw = (n.params['w'] as num).toDouble();
      final rh = (n.params['h'] as num).toDouble();
      final sx = (img.width * rx).round();
      final sy = (img.height * ry).round();
      final sw = math.max(1, (img.width * rw).round());
      final sh = math.max(1, (img.height * rh).round());
      return _newCanvas(sw, sh, (c) {
        c.drawImageRect(
            img,
            ui.Rect.fromLTWH(sx.toDouble(), sy.toDouble(), sw.toDouble(), sh.toDouble()),
            ui.Offset.zero & ui.Size(sw.toDouble(), sh.toDouble()),
            ui.Paint());
      });

    case Ops.adjust:
    case Ops.preset:
      final params = n.op == Ops.preset
          ? Map<String, double>.of(presetExpansion(n.params['name'] as String))
          : {for (final e in n.params.entries) e.key: (e.value as num).toDouble()};
      return _applyAdjust(img, params);

    case Ops.annotate:
      return _applyAnnotate(img, n.params);

    case Ops.resize:
      final target = sizeAfter([n], img.width, img.height);
      return _newCanvas(target.w, target.h, (c) {
        final p = ui.Paint()..filterQuality = ui.FilterQuality.low; // 双线性
        c.drawImageRect(
            img,
            ui.Offset.zero & ui.Size(img.width.toDouble(), img.height.toDouble()),
            ui.Offset.zero & ui.Size(target.w.toDouble(), target.h.toDouble()),
            p);
      });

    case Ops.aiEdit:
      // 生成式节点：S4 接入云端图像模型后实现，当前跳过不改变像素。
      return img;

    default:
      return img;
  }
}

ui.ColorFilter? adjustColorFilter(Map<String, double> p) {
  // 4x5 颜色矩阵（RGBA 通道 + 偏移列），依次合成：饱和度 → 对比度 → 亮度/色温
  final b = p['brightness'] ?? 0;
  final c = p['contrast'] ?? 0;
  final s = p['saturation'] ?? 0;
  final t = p['temperature'] ?? 0;

  final sat = (s + 1).clamp(0, 2).toDouble();
  final sr = (1 - sat) * 0.213, sg = (1 - sat) * 0.715, sb = (1 - sat) * 0.072;
  final ct = (c + 1).clamp(0, 2).toDouble();
  final contrastOff = 0.5 * (1 - ct) * 255;

  double diag(double l) => ct * (l + sat);
  double off(double tempShift) => ct * tempShift + contrastOff + b * 255;

  final m = <double>[
    diag(sr), ct * sg, ct * sb, 0, off(t * 40), // R：暖调加红
    ct * sr, diag(sg), ct * sb, 0, off(-t * 25), // G
    ct * sr, ct * sg, diag(sb), 0, off(-t * 40), // B：暖调减蓝
    0, 0, 0, 1, 0, // A
  ];
  return ui.ColorFilter.matrix(m);
}

Future<ui.Image> _applyAdjust(ui.Image img, Map<String, double> p) async {
  final vignette = p['vignette'] ?? 0;
  final base = await _newCanvas(img.width, img.height, (c) {
    final paint = ui.Paint();
    final filter = adjustColorFilter(p);
    if (filter != null) paint.colorFilter = filter;
    c.drawImage(img, ui.Offset.zero, paint);

    if (vignette > 0) {
      final r = math.max(img.width, img.height).toDouble();
      c.drawRect(
          ui.Offset.zero & ui.Size(img.width.toDouble(), img.height.toDouble()),
          ui.Paint()
            ..shader = ui.Gradient.radial(
              ui.Offset(img.width / 2, img.height / 2),
              r * 0.75,
              [
                ui.Color.fromRGBO(0, 0, 0, 0),
                ui.Color.fromRGBO(0, 0, 0, vignette.clamp(0, 1)),
              ],
            ));
    }
  });
  return base;
}

/// 在给定画布上按输出尺寸绘制单个标注节点（矢量部分，屏幕/离屏共用）。
/// 马赛克在屏幕预览下以半透明块近似（导出走离屏精确像素化）。
void paintAnnotateVectors(ui.Canvas c, ui.Size outSize, Map<String, Object?> params) {
  final kind = params['kind'] as String;
  final size = ((params['size'] as num?)?.toDouble() ?? 24);
  final colorValue = ((params['color'] as num?) ?? 0xFFE5615C).toInt();
  final paint = ui.Paint()
    ..color = ui.Color(colorValue)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth =
        ((params['strokeWidth'] as num?)?.toDouble()) ?? math.max(2, size * 0.08).toDouble();

  // 涂鸦只有 points 路径点（无 x/y 锚点），优先处理并返回
  if (kind == AnnotateKinds.doodle) {
    final pts = (params['points'] as List? ?? [])
        .map((e) => ui.Offset(
            (((e as Map)['x'] as num?)?.toDouble() ?? 0) * outSize.width,
            (((e)['y'] as num?)?.toDouble() ?? 0) * outSize.height))
        .toList();
    final stroke = ui.Paint()
      ..color = ui.Color(colorValue)
      ..style = ui.PaintingStyle.stroke
      ..strokeCap = ui.StrokeCap.round
      ..strokeWidth = paint.strokeWidth;
    for (var i = 1; i < pts.length; i++) {
      c.drawLine(pts[i - 1], pts[i], stroke);
    }
    return;
  }

  // 其余类型：x/y 锚点（容错缺失，缺失按 0 处理不抛帧异常）
  final x = ((params['x'] as num?) ?? 0).toDouble() * outSize.width;
  final y = ((params['y'] as num?) ?? 0).toDouble() * outSize.height;

  ui.Offset? end;
  if (params['x2'] is num && params['y2'] is num) {
    end = ui.Offset(
      (params['x2'] as num).toDouble() * outSize.width,
      (params['y2'] as num).toDouble() * outSize.height,
    );
  }

  switch (kind) {
    case AnnotateKinds.text:
      final text = (params['text'] as String?) ?? '';
      final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: size))
        ..pushStyle(ui.TextStyle(color: ui.Color(colorValue)))
        ..addText(text);
      final para = builder.build()
        ..layout(ui.ParagraphConstraints(width: outSize.width));
      c.drawParagraph(para, ui.Offset(x, y));
    case AnnotateKinds.arrow:
      if (end != null) {
        c.drawLine(ui.Offset(x, y), end, paint);
        final dir = end - ui.Offset(x, y);
        final len = dir.distance;
        if (len > 0) {
          ui.Offset rot(ui.Offset v, double a) => ui.Offset(
                v.dx * math.cos(a) - v.dy * math.sin(a),
                v.dx * math.sin(a) + v.dy * math.cos(a),
              );
          final u = dir / len;
          final left = end - rot(u, math.pi / 6) * (size * 0.6);
          final right = end - rot(u, -math.pi / 6) * (size * 0.6);
          c.drawLine(end, left, paint);
          c.drawLine(end, right, paint);
        }
      }
    case AnnotateKinds.rect:
      if (end != null) {
        c.drawRect(ui.Rect.fromPoints(ui.Offset(x, y), end), paint);
      }
    case AnnotateKinds.ellipse:
      if (end != null) {
        c.drawOval(ui.Rect.fromPoints(ui.Offset(x, y), end), paint);
      }
    case AnnotateKinds.mosaic:
      if (end != null) {
        final rect = ui.Rect.fromPoints(ui.Offset(x, y), end);
        c.drawRect(rect, ui.Paint()..color = const ui.Color(0x66000000));
      }
    case AnnotateKinds.doodle:
      final pts = (params['points'] as List? ?? [])
          .map((e) => ui.Offset(
              ((e as Map)['x'] as num).toDouble() * outSize.width,
              (e['y'] as num).toDouble() * outSize.height))
          .toList();
      for (var i = 1; i < pts.length; i++) {
        c.drawLine(pts[i - 1], pts[i], paint..strokeCap = ui.StrokeCap.round);
      }
  }
}

Future<ui.Image> _applyAnnotate(ui.Image img, Map<String, Object?> params) async {
  return _newCanvas(img.width, img.height, (c) {
    paintAnnotateVectors(c, ui.Size(img.width.toDouble(), img.height.toDouble()), params);
  });
}
