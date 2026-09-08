// 真机集成测试：文字标注拖框位置必须与提交后导出结果一致（像素级）。
// 流程：纯色测试图 → 文字工具 → 在 rel(0.3,0.2)-(0.7,0.5) 拖虚线框 →
// 输入文字确认 → 导出 PNG → 红色文字像素包围盒必须落在拖框位置附近。
// 运行: flutter test integration_test/editor_text_pos_test.dart -d windows
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent_image_viewer/app_state.dart';
import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/core/scanner.dart';
import 'package:agent_image_viewer/main.dart' as app;
import 'package:agent_image_viewer/ui/editor/editor_page.dart';
import 'package:agent_image_viewer/ui/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _writeSolidPng(File f, int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  c.drawRect(ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFE6E6E6));
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
    tmp = await Directory.systemTemp.createTemp('aiv_text_pos');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  testWidgets('文字标注：拖框位置 = 导出位置（像素级）', (tester) async {
    await app.appMain(const []);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    final testFile = File('${tmp.path}${Platform.pathSeparator}pos.png');
    await _writeSolidPng(testFile, 800, 600);
    final ctx = tester.element(find.byType(HomePage));
    final state = AppStateScope.of(ctx, listen: false);
    final entry = ImageEntry(
        path: testFile.path, name: 'pos.png', sizeBytes: 1, mtimeMs: 1);
    state.library.upsert(entry);
    await tester.pump(const Duration(milliseconds: 300));

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

    // 文字工具 + rel(0.3,0.2)-(0.7,0.5) 拖虚线框
    await tester.tap(find.byTooltip('标注'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('文字'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.dragFrom(
        tl + Offset(0.3 * drawW, 0.2 * drawH),
        Offset(0.4 * drawW, 0.3 * drawH));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), 'test');
    await tester.tap(find.text('确定'));
    await tester.pump(const Duration(milliseconds: 400));

    final textNodes = c.pipeline.nodes
        .where((n) => n.params['kind'] == AnnotateKinds.text);
    expect(textNodes, isNotEmpty, reason: '文字标注应已提交');
    final params = textNodes.single.params;
    // ignore: avoid_print
    print('DEBUG committed text params=$params');

    // 导出 PNG
    await tester.tap(find.text('导出'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('另存副本'));
    await tester.pump(const Duration(seconds: 1));
    final exported = File(
        '${testFile.path.substring(0, testFile.path.lastIndexOf('.'))}_edited.png');
    expect(exported.existsSync(), isTrue);

    // 找红色文字像素（纯灰底上任何红像素都属于标注）
    final (outPixels, w, h) = await _decodePixels(exported.path);
    var minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final r = outPixels[i], g = outPixels[i + 1], b = outPixels[i + 2];
        if (r > 170 && g < 170 && b < 170 && r - g > 50 && r - b > 50) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    expect(maxX, greaterThan(minX), reason: '导出图应包含红色文字');
    final rw = w.toDouble(), rh = h.toDouble();
    // ignore: avoid_print
    print('DEBUG textBBox rel=(${(minX / rw).toStringAsFixed(3)},'
        '${(minY / rh).toStringAsFixed(3)})-(${(maxX / rw).toStringAsFixed(3)},'
        '${(maxY / rh).toStringAsFixed(3)})');

    // 文字锚点=框左上角：文字包围盒应从拖框左上角附近开始
    expect(minX / rw, inInclusiveRange(0.25, 0.35),
        reason: '文字左边缘应落在拖框左缘附近');
    expect(minY / rh, inInclusiveRange(0.15, 0.45),
        reason: '文字上边缘应在拖框上缘附近（含字体留白）');

    exported.deleteSync();
  });
}
