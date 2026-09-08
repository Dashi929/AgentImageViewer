// 真机回归：马赛克预览必须在真实 GPU 后端产生真实像素化。
// 回归背景：compose「缩小→放大」图像滤镜方案在软件渲染（flutter test，
// preview_geometry_test）下断言全绿，但 Windows/Android Impeller 真机实测
// 完全不生效（用户报告「马赛克效果完全不明显」）。本测试在真实引擎进程内
// 直接验证 paintMosaicRegion 的输出像素，防止再被纯软件渲染测试假绿掩盖。
// 运行: flutter test integration_test/mosaic_backend_pixel_test.dart -d windows
import 'dart:ui' as ui;

import 'package:agent_image_viewer/core/pipeline/preview_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<ui.Image> _stripes(int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  c.drawRect(ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF000000));
  for (var x = 0; x < w; x += 4) {
    c.drawRect(
        ui.Offset(x.toDouble(), 0) & ui.Size(2, h.toDouble()),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  }
  return rec.endRecording().toImage(w, h);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('paintMosaicRegion 真实后端像素化：块内均匀且异于源', (tester) async {
    // 2px 黑白竖条纹 200×100；马赛克区域 (60,10)-(140,90)，bs=8 → 10×10 网格，
    // 块锚在区域起点 (60,10)
    const w = 200, h = 100;
    final src = await _stripes(w, h);
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
    canvas.drawImage(src, ui.Offset.zero, ui.Paint());
    paintMosaicRegion(
      canvas,
      source: src,
      geo: Matrix4.identity(),
      rect: ui.Rect.fromLTWH(60, 10, 80, 80),
      out: ui.Size(w.toDouble(), h.toDouble()),
    );
    final img = await rec.endRecording().toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final px = data!.buffer.asUint8List();

    int rgb(int x, int y) {
      final i = (y * w + x) * 4;
      return (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
    }

    // 块内均匀（8px 块：x∈[60,68)/[68,76)…，y∈[40,48)…）
    expect(rgb(64, 50), rgb(66, 50), reason: '块内横向均匀');
    expect(rgb(100, 44), rgb(100, 46), reason: '块内纵向均匀');
    expect(rgb(62, 12), rgb(64, 12), reason: '左上角块内均匀');

    // 区域内多数像素与源条纹强差异（像素化确实发生，而非原样透出）
    var changed = 0, total = 0;
    for (var y = 11; y < 89; y++) {
      for (var x = 61; x < 139; x++) {
        final i = (y * w + x) * 4;
        final isStripeWhite = (x % 4) < 2;
        final expectLum = isStripeWhite ? 255 : 0;
        final lum = px[i];
        total++;
        if ((lum - expectLum).abs() > 60) changed++;
      }
    }
    expect(changed / total, greaterThan(0.3),
        reason: '马赛克区域应大面积偏离源条纹（真实像素化）');

    // 区域外保持源条纹（白条在 x mod 4 ∈ {0,1}，取跨条纹边界的采样对）
    expect(rgb(31, 50), isNot(rgb(32, 50)), reason: '区域外保持条纹');
  });
}
