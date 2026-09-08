// 真机回归：标注「拖拽中」与「提交后」的渲染必须一致（位置/粗细/浓淡），
// 马赛克拖拽中必须已经可见像素化。
// 回归背景（2026-09-08 用户反馈）：① 拖拽层曾在控件坐标系画固定 2 控件px
// 描边、且在调色滤镜之外——提交后变 2×fit 输出px 并被调色，被感知为「拖动时
// 颜色比实际应用的浅」；② 马赛克拖拽/提交预览用 compose 图像滤镜像素化，
// 真实 GPU 后端不生效，「马赛克效果完全不明显」。
// 验证方式：拖拽中从真实组件树取出 _AnnotateDragPainter 实例，与提交后的
// EditorPreviewPainter 各自离屏栅格化，对比描边像素量与包围盒。
// （不走 layer.toImage 抓窗口帧：Impeller/Windows 下 toImage 栅格化带 DPR
// 缩放裁剪，内容与逻辑坐标错位，无法用于逐像素断言。）
// 运行: flutter test integration_test/drag_commit_parity_test.dart -d windows
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent_image_viewer/app_state.dart';
import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/core/pipeline/preview_painter.dart';
import 'package:agent_image_viewer/core/scanner.dart';
import 'package:agent_image_viewer/main.dart' as app;
import 'package:agent_image_viewer/ui/editor/editor_page.dart';
import 'package:agent_image_viewer/ui/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

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

/// 离屏栅格化 painter 到 size 画布（可先施加平移）。
Future<ui.Image> _raster(CustomPainter painter, Size size,
    {Offset translate = Offset.zero}) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, Offset.zero & size);
  if (translate != Offset.zero) c.translate(translate.dx, translate.dy);
  painter.paint(c, size);
  return rec.endRecording().toImage(size.width.round(), size.height.round());
}

Future<Uint8List> _bytes(ui.Image img) async {
  final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  return d!.buffer.asUint8List();
}

/// 非透明像素统计（拖拽 painter 只画描边，底透明）。
({int count, Rect bbox}) _opaqueStats(Uint8List b, int w, int h) {
  var minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1, count = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (b[(y * w + x) * 4 + 3] > 0) {
        count++;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  return (
    count: count,
    bbox: maxX < 0
        ? Rect.zero
        : Rect.fromLTRB(
            minX.toDouble(), minY.toDouble(), maxX.toDouble(), maxY.toDouble()),
  );
}

/// 两帧差异像素统计。
({int count, Rect bbox}) _diffStats(Uint8List a, Uint8List b, int w, int h) {
  var minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1, count = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final d = (a[i] - b[i]).abs() +
          (a[i + 1] - b[i + 1]).abs() +
          (a[i + 2] - b[i + 2]).abs();
      if (d > 60) {
        count++;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  return (
    count: count,
    bbox: maxX < 0
        ? Rect.zero
        : Rect.fromLTRB(
            minX.toDouble(), minY.toDouble(), maxX.toDouble(), maxY.toDouble()),
  );
}

void _expectBBoxClose(Rect a, Rect b, String what) {
  expect((a.left - b.left).abs(), lessThan(4), reason: '$what 左缘应重合');
  expect((a.top - b.top).abs(), lessThan(4), reason: '$what 上缘应重合');
  expect((a.right - b.right).abs(), lessThan(4), reason: '$what 右缘应重合');
  expect((a.bottom - b.bottom).abs(), lessThan(4), reason: '$what 下缘应重合');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('标注拖拽中与提交后渲染一致（真实引擎，离屏逐像素）', (tester) async {
    await app.appMain(const []);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    final tmp = await Directory.systemTemp.createTemp('aiv_parity');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final testFile = File('${tmp.path}${Platform.pathSeparator}parity.png');
    await _writeStripePng(testFile, 800, 600);

    final ctx = tester.element(find.byType(HomePage));
    final state = AppStateScope.of(ctx, listen: false);
    final entry = ImageEntry(
        path: testFile.path, name: 'parity.png', sizeBytes: 1, mtimeMs: 1);
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

    final canvasRect = tester.getRect(find.descendant(
        of: find.byType(EditorPage),
        matching: find.byWidgetPredicate(
            (w) => w is GestureDetector && w.onPanStart != null,
            description: '画布手势区')));
    final canvasSize = canvasRect.size;

    final dragPainterFinder = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_AnnotateDragPainter',
        description: '标注拖拽预览 painter');

    await tester.tap(find.byTooltip('标注'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('矩形'), findsOneWidget, reason: '标注属性面板应已激活');

    // ---------- 矩形：拖拽中描边 ≡ 提交后描边 ----------
    await tester.tap(find.text('矩形'));
    await tester.pump(const Duration(milliseconds: 300));

    final canvasCenter = canvasRect.center;
    final from = canvasCenter - const Offset(160, 60);
    final move = Offset(canvasRect.width * 0.3, canvasRect.height * 0.25);

    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.moveBy(const Offset(40, 25));
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(move - const Offset(40, 25));
    await tester.pump(const Duration(milliseconds: 60));

    // ignore: avoid_print
    print('DEBUG mid-drag painterCount=${dragPainterFinder.evaluate().length} '
        'nodes=${ctrl!.pipeline.nodes.length} '
        'from=$from move=$move canvasRect=$canvasRect');

    // 从真实组件树取拖拽 painter 实例，离屏复现其绘制（a/b 已是画布本地坐标）
    final dragWidget = tester.widget<CustomPaint>(dragPainterFinder);
    final dragImg = await _raster(dragWidget.painter!, canvasSize);
    final dragB = await _bytes(dragImg);
    final dragStats = _opaqueStats(dragB, canvasSize.width.round(),
        canvasSize.height.round());
    expect(dragStats.count, greaterThan(50),
        reason: '拖拽中应离屏复现出矩形描边（count=${dragStats.count}）');

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(ctrl.pipeline.nodes.last.params['kind'], AnnotateKinds.rect);

    // 提交后：同一画布尺寸下 EditorPreviewPainter 有/无该节点的差分 = 描边
    final withAnnot = await _raster(
        EditorPreviewPainter(
            source: ctrl.source, nodes: ctrl.pipeline.nodes, generation: 1),
        canvasSize);
    final withoutAnnot = await _raster(
        EditorPreviewPainter(
            source: ctrl.source,
            nodes: ctrl.pipeline.nodes.sublist(0, ctrl.pipeline.nodes.length - 1),
            generation: 1),
        canvasSize);
    final commitStats = _diffStats(await _bytes(withAnnot),
        await _bytes(withoutAnnot), canvasSize.width.round(),
        canvasSize.height.round());
    expect(commitStats.count, greaterThan(50),
        reason: '提交后应渲染出矩形描边（count=${commitStats.count}）');

    // ignore: avoid_print
    print('DEBUG rect drag=${dragStats.count} @${dragStats.bbox} '
        'commit=${commitStats.count} @${commitStats.bbox}');
    expect(dragStats.count / commitStats.count, inInclusiveRange(0.7, 1.4),
        reason: '拖拽中 ${dragStats.count} vs 提交后 ${commitStats.count} '
            '描边像素量应同量级（粗细浓淡一致）');
    _expectBBoxClose(dragStats.bbox, commitStats.bbox, '矩形描边');

    // ---------- 马赛克：拖拽中已可见像素化，提交后保持 ----------
    await tester.tap(find.text('马赛克'));
    await tester.pump(const Duration(milliseconds: 300));

    final mFrom = canvasRect.topLeft +
        Offset(canvasRect.width * 0.15, canvasRect.height * 0.55);
    final mMove = Offset(canvasRect.width * 0.3, canvasRect.height * 0.3);
    final mRegion = Rect.fromPoints(mFrom, mFrom + mMove)
        .translate(-canvasRect.topLeft.dx, -canvasRect.topLeft.dy);

    final mg = await tester.startGesture(mFrom);
    await tester.pump(const Duration(milliseconds: 80));
    await mg.moveBy(const Offset(40, 25));
    await tester.pump(const Duration(milliseconds: 60));
    await mg.moveBy(mMove - const Offset(40, 25));
    await tester.pump(const Duration(milliseconds: 60));

    final mDragWidget = tester.widget<CustomPaint>(dragPainterFinder);
    final mDragImg = await _raster(mDragWidget.painter!, canvasSize);
    final mDragB = await _bytes(mDragImg);
    final mDragStats = _opaqueStats(mDragB, canvasSize.width.round(),
        canvasSize.height.round());
    expect(mDragStats.count, greaterThan(500),
        reason: '拖拽中马赛克区域应已可见像素化（count=${mDragStats.count}）');
    _expectBBoxClose(mDragStats.bbox, mRegion, '马赛克拖拽区域');

    await mg.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(ctrl.pipeline.nodes.last.params['kind'], AnnotateKinds.mosaic);

    final mWith = await _raster(
        EditorPreviewPainter(
            source: ctrl.source, nodes: ctrl.pipeline.nodes, generation: 1),
        canvasSize);
    final mWithout = await _raster(
        EditorPreviewPainter(
            source: ctrl.source,
            nodes: ctrl.pipeline.nodes.sublist(0, ctrl.pipeline.nodes.length - 1),
            generation: 1),
        canvasSize);
    final mCommitStats = _diffStats(await _bytes(mWith), await _bytes(mWithout),
        canvasSize.width.round(), canvasSize.height.round());
    expect(mCommitStats.count, greaterThan(500),
        reason: '提交后马赛克区域应保持像素化（count=${mCommitStats.count}）');
    // ignore: avoid_print
    print('DEBUG mosaic drag=${mDragStats.count} commit=${mCommitStats.count}');
    _expectBBoxClose(mCommitStats.bbox, mRegion, '马赛克提交区域');

    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
