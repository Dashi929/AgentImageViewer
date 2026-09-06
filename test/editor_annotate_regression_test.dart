import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/core/db/json_store.dart';
import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/core/image/image_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_utils.dart';

Future<ui.Image> _solid(int w, int h, int color) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  c.drawRect(ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
      ui.Paint()..color = ui.Color(color));
  return rec.endRecording().toImage(w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aiv_annot_reg');
  });
  tearDown(() => deleteDirWithRetry(tmp));

  test('回归：标注入栈后预览重算成功，淘汰压力下源图/预览图不被释放', () async {
    final src = await _solid(1600, 1000, 0xFF4C9BE8);
    final prev = await _solid(1024, 640, 0xFF4C9BE8);

    final c = EditorController(
      imageId: 'annot-regression',
      source: src,
      store: JsonStore(baseDir: tmp),
      previewSource: prev,
    );
    addTearDown(c.dispose);

    // 画一个矩形标注（用户操作：标注拖拽 → addNode）
    c.addNode(FilterNode(op: Ops.annotate, params: {
      'kind': AnnotateKinds.rect,
      'x': 0.2,
      'y': 0.2,
      'x2': 0.7,
      'y2': 0.6,
    }));
    final ok = await c.recomputePreview();
    expect(ok, isTrue);
    final previewAfterAnnotate = c.preview;
    expect(previewAfterAnnotate, isNotNull);

    // 淘汰压力：向 ImageManager 大量注入新解码（旧 bug 会释放源/预览图）
    final mgr = ImageManager(thumbCacheDir: Directory('${tmp.path}/thumbs'),
        capacityBytes: 4 * 1024 * 1024);
    for (var i = 0; i < 20; i++) {
      final filler = await _solid(512, 384, 0xFF000000 | (i * 13 + 7));
      final data = await filler.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${tmp.path}/filler$i.png');
      await file.writeAsBytes(data!.buffer.asUint8List());
      await mgr.decode(file.path, i, autoPin: false);
      await file.delete();
    }

    // 源/预览图被钉住：再次求值仍成功且结果稳定
    final ok2 = await c.recomputePreview();
    expect(ok2, isFalse, reason: '管线未变，预览保持');
    expect(c.preview, same(previewAfterAnnotate));
    mgr.dispose();
  });

  test('autoPin：decode 后即使大量新解码也不淘汰、不释放', () async {
    final mgr = ImageManager(thumbCacheDir: Directory('${tmp.path}/thumbs2'),
        capacityBytes: 2 * 1024 * 1024);
    // 被钉住的图（约 3MB 位图）
    final pinnedImg = await _solid(900, 700, 0xFF123456);
    final data = await pinnedImg.toByteData(format: ui.ImageByteFormat.png);
    final f = File('${tmp.path}/pinned.png');
    await f.writeAsBytes(data!.buffer.asUint8List());
    final pinned = await mgr.decode(f.path, 1, autoPin: true);
    expect(mgr.isPinned(pinned.cacheKey), isTrue);

    // 压力：远超预算的新解码
    for (var i = 0; i < 10; i++) {
      final img = await _solid(700, 500, 0xFF000000 | (i * 17 + 11));
      final d = await img.toByteData(format: ui.ImageByteFormat.png);
      final ff = File('${tmp.path}/f$i.png');
      await ff.writeAsBytes(d!.buffer.asUint8List());
      await mgr.decode(ff.path, i, autoPin: false);
      await ff.delete();
    }

    // 钉住条目未被淘汰：返回同一实例（未释放）
    final again = await mgr.decode(f.path, 1, autoPin: false);
    expect(identical(again, pinned), isTrue);
    mgr.dispose();
  });
}
