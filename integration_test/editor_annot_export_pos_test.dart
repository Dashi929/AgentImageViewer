// 真机集成测试：标注拖拽位置必须与最终导出结果一致（像素级）。
// 流程：自建黑白条纹测试图入库 → 编辑器中在已知相对位置拖马赛克 → 导出 PNG
// → 与原图逐像素对比，像素化差异区域包围盒必须落在拖拽相对区域内。
// （测试图必须是条纹而非纯色：真实像素化对纯色区域输出不变、差异恒为零，
// 旧「压暗区域」断言是半透明黑块假实现时代的产物。）
// 运行: flutter test integration_test/editor_annot_export_pos_test.dart -d windows
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_image_viewer/app_state.dart';
import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/core/scanner.dart';
import 'package:agent_image_viewer/main.dart' as app;
import 'package:agent_image_viewer/ui/editor/editor_page.dart';
import 'package:agent_image_viewer/ui/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 2px 白条黑底竖条纹（真实像素化后块内颜色与源条纹必然强差异）。
Future<void> _writeStripePng(File f, int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  c.drawRect(ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF000000));
  for (var x = 0; x < w; x += 4) {
    c.drawRect(
        ui.Offset(x.toDouble(), 0) & ui.Size(2, h.toDouble()),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  }
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  await f.writeAsBytes(data!.buffer.asUint8List());
}

Future<(Uint8List, int, int)> _decodePixels(String path) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final w = frame.image.width, h = frame.image.height;
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return (data!.buffer.asUint8List(), w, h);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aiv_export_pos');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  testWidgets('马赛克拖拽位置与导出结果一致（像素级）', (tester) async {
    await app.appMain(const []);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    // 自建测试图入库（黑白条纹：马赛克像素化后与源差异明显且可控）
    final testFile = File('${tmp.path}${Platform.pathSeparator}pos.png');
    await _writeStripePng(testFile, 800, 600);
    final ctx = tester.element(find.byType(HomePage));
    final state = AppStateScope.of(ctx, listen: false);
    final entry = ImageEntry(
        path: testFile.path, name: 'pos.png', sizeBytes: 1, mtimeMs: 1);
    state.library.upsert(entry);
    await tester.pump(const Duration(milliseconds: 300));

    final (srcPixels, _, _) = await _decodePixels(testFile.path);

    NavigatorStateEx.editor.value = entry;
    EditorController? ctrl;
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      ctrl = EditorController.controllerFor(
          entry.path.hashCode.toUnsigned(32).toString());
      if (ctrl != null) break;
    }
    expect(ctrl, isNotNull);
    final c = ctrl!;

    // 画布矩形与图像显示矩形（与页面同一适配公式）
    final canvasRect = tester.getRect(find.descendant(
        of: find.byType(EditorPage),
        matching: find.byWidgetPredicate(
            (w) => w is GestureDetector && w.onPanStart != null,
            description: '画布手势区')));
    final outW = c.source.width.toDouble(), outH = c.source.height.toDouble();
    final fit = (canvasRect.width / outW) < (canvasRect.height / outH)
        ? canvasRect.width / outW
        : canvasRect.height / outH;
    final drawW = outW * fit, drawH = outH * fit;
    final tl = Offset(
        canvasRect.left + (canvasRect.width - drawW) / 2,
        canvasRect.top + (canvasRect.height - drawH) / 2);

    // 马赛克：rel(0.2,0.25) → (0.6,0.65)
    await tester.tap(find.byTooltip('标注'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('马赛克'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.dragFrom(
        tl + Offset(0.2 * drawW, 0.25 * drawH),
        Offset(0.4 * drawW, 0.4 * drawH));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
        c.pipeline.nodes
            .where((n) => n.params['kind'] == AnnotateKinds.mosaic),
        isNotEmpty);
    // ignore: avoid_print
    print('DEBUG canvasRect=$canvasRect draw=${drawW}x$drawH tl=$tl');
    // ignore: avoid_print
    print('DEBUG mosaic=${c.pipeline.nodes.last.params}');

    // 导出 PNG（另存副本）
    await tester.tap(find.text('导出'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('另存副本'));
    await tester.pump(const Duration(seconds: 1));
    final exported = File(
        '${testFile.path.substring(0, testFile.path.lastIndexOf('.'))}_edited.png');
    expect(exported.existsSync(), isTrue, reason: '导出文件应存在');

    // 逐像素对比：像素化差异区域的包围盒
    final (outPixels, w, h) = await _decodePixels(exported.path);
    var minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final d = (outPixels[i] - srcPixels[i]).abs() +
            (outPixels[i + 1] - srcPixels[i + 1]).abs() +
            (outPixels[i + 2] - srcPixels[i + 2]).abs();
        if (d > 60) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    expect(maxX, greaterThan(minX), reason: '应检测到马赛克像素化差异区域');
    // ignore: avoid_print
    print('DEBUG exported=${w}x$h diffBBox=($minX,$minY)-($maxX,$maxY)');
    final rw = w.toDouble(), rh = h.toDouble();
    expect(minX / rw, inInclusiveRange(0.15, 0.25),
        reason: '左边界应在拖拽位置附近 (minX=${(minX / rw).toStringAsFixed(3)})');
    expect(minY / rh, inInclusiveRange(0.20, 0.30),
        reason: '上边界应在拖拽位置附近 (minY=${(minY / rh).toStringAsFixed(3)})');
    expect(maxX / rw, inInclusiveRange(0.55, 0.65),
        reason: '右边界应在拖拽位置附近 (maxX=${(maxX / rw).toStringAsFixed(3)})');
    expect(maxY / rh, inInclusiveRange(0.60, 0.70),
        reason: '下边界应在拖拽位置附近 (maxY=${(maxY / rh).toStringAsFixed(3)})');

    exported.deleteSync();
  });
}
