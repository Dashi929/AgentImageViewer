import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_utils.dart';

Future<ui.Image> _solid(int w, int h, int color) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  c.drawRect(
      ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
      ui.Paint()
        ..color = ui.Color(color)
        ..style = ui.PaintingStyle.fill);
  return rec.endRecording().toImage(w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aiv_editor_test');
  });
  tearDown(() => deleteDirWithRetry(tmp));

  test('编辑历史不持久化：不落盘，重开编辑器从空白开始', () async {
    final src = await _solid(50, 50, 0xFF204080);
    final c1 = EditorController(imageId: 'img7', source: src);
    await c1.addNode(FilterNode(op: Ops.adjust, params: {'brightness': 0.2}));
    await c1.addNode(FilterNode(op: Ops.preset, params: {'name': 'bw'}));
    expect(c1.pipeline.nodes.map((n) => n.op).toList(), ['adjust', 'preset']);
    c1.dispose();

    // 退出后重开（新控制器）：历史不恢复
    final c2 = EditorController(imageId: 'img7', source: src);
    addTearDown(c2.dispose);
    expect(c2.pipeline.nodes, isEmpty);
    expect(Directory('${tmp.path}${Platform.pathSeparator}edits').existsSync(),
        isFalse,
        reason: '编辑历史不再写盘');
  });

  test('撤销/重做经控制器生效', () async {
    final src = await _solid(40, 40, 0xFF204080);
    final c = EditorController(imageId: 'x', source: src);
    addTearDown(c.dispose);
    await c.addNode(FilterNode(op: Ops.rotate, params: {'deg': 90}));
    await c.undo();
    expect(c.pipeline.nodes, isEmpty);
    await c.redo();
    expect(c.pipeline.nodes.map((n) => n.op), ['rotate']);
  });

  test('导出 PNG 与 JPG 的文件头正确', () async {
    final src = await _solid(32, 32, 0xFF204080);
    final c = EditorController(imageId: 'x', source: src);
    addTearDown(c.dispose);
    await c.addNode(FilterNode(op: Ops.resize, params: {'width': 16}));

    final png = await c.exportBytes(ExportFormat.png);
    expect(png.bytes.sublist(0, 8),
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); // PNG 签名
    expect((png.width, png.height), (16, 16));

    final jpg = await c.exportBytes(ExportFormat.jpg, quality: 80);
    expect(jpg.bytes[0], 0xFF);
    expect(jpg.bytes[1], 0xD8); // JPEG SOI
  });

  test('writeFile 覆盖时自动生成 .bak 备份', () async {
    final src = await _solid(16, 16, 0xFF204080);
    final c = EditorController(imageId: 'x', source: src);
    addTearDown(c.dispose);

    final target = '${tmp.path}${Platform.pathSeparator}out.png';
    await c.writeFile(target, [1, 2, 3]);
    await c.writeFile(target, [9, 9]);

    expect(await File('$target.bak').readAsBytes(), [1, 2, 3]);
    expect(await File(target).readAsBytes(), [9, 9]);
  });

  test('generation 随节点/历史变化递增（驱动画布重绘）', () async {
    final src = await _solid(64, 32, 0xFF204080);
    final c = EditorController(imageId: 'x', source: src);
    addTearDown(c.dispose);
    final g0 = c.generation;
    await c.addNode(
        FilterNode(op: Ops.crop, params: {'x': 0, 'y': 0, 'w': 0.5, 'h': 0.5}));
    expect(c.generation, g0 + 1);
    await c.undo();
    expect(c.generation, g0 + 2);
    await c.redo();
    expect(c.generation, g0 + 3);
  });

  test('导出走全尺寸 source 离屏合成', () async {
    final src = await _solid(3000, 2000, 0xFF204080);
    final c = EditorController(imageId: 'p', source: src);
    await c.addNode(FilterNode(
        op: Ops.crop, params: {'x': 0, 'y': 0, 'w': 0.5, 'h': 0.5}));
    final png = await c.exportBytes(ExportFormat.png);
    expect((png.width, png.height), (1500, 1000),
        reason: '导出为离屏精确合成');
    c.dispose();
  });
}
