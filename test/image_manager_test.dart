import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_image_viewer/core/image/image_manager.dart';
import 'package:flutter_test/flutter_test.dart';

Future<File> _writePng(Directory dir, String name, int w, int h, int color) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  c.drawRect(ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
      ui.Paint()..color = ui.Color(color));
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return File('${dir.path}${Platform.pathSeparator}$name')
      .writeAsBytes(data!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory thumbs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aiv_mgr_test');
    thumbs = Directory('${tmp.path}${Platform.pathSeparator}thumbs');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('decode 返回真实尺寸，二次解码命中内存缓存', () async {
    final f = await _writePng(tmp, 'a.png', 40, 20, 0xFF00FF00);
    final mgr = ImageManager(thumbCacheDir: thumbs);
    final d1 = await mgr.decode(f.path, 100);
    expect(d1.width, 40);
    expect(d1.height, 20);
    final d2 = await mgr.decode(f.path, 100);
    expect(identical(d1, d2), isTrue, reason: '缓存命中应返回同一实例');
    mgr.dispose();
  });

  test('mtime 变化后视为新条目', () async {
    final f = await _writePng(tmp, 'b.png', 10, 10, 0xFFFF0000);
    final mgr = ImageManager(thumbCacheDir: thumbs);
    final d1 = await mgr.decode(f.path, 100);
    final d2 = await mgr.decode(f.path, 200);
    expect(identical(d1, d2), isFalse);
    mgr.dispose();
  });

  test('字节预算淘汰：钉住的条目不淘汰，未钉的按 LRU 淘汰', () async {
    // 每张 64x64x4 = 16KB，预算 2 张
    final mgr = ImageManager(thumbCacheDir: thumbs, capacityBytes: 32 * 1024);
    final f1 = await _writePng(tmp, 'c1.png', 64, 64, 0xFF0000FF);
    final f2 = await _writePng(tmp, 'c2.png', 64, 64, 0xFF00FF00);
    final f3 = await _writePng(tmp, 'c3.png', 64, 64, 0xFFFF0000);

    final d1 = await mgr.decode(f1.path, 1);
    mgr.pin(d1.cacheKey);
    final d2 = await mgr.decode(f2.path, 1);
    await mgr.decode(f3.path, 1);

    // 预算 2 张：d2（最旧未钉）应被淘汰，d1 被钉住保留，d3 最新保留
    expect(mgr.usedBytes, lessThanOrEqualTo(32 * 1024));
    // 重新取出 d1：仍是同一实例（未销毁）
    expect(mgr.decode(f1.path, 1), completion(same(d1)));
    // d2 已被淘汰：重新解码得到新实例
    final d2b = await mgr.decode(f2.path, 1);
    expect(identical(d2, d2b), isFalse);
    mgr.unpin(d1.cacheKey);
    mgr.dispose();
  });

  test('缩略图 target 解码落盘，新实例命中磁盘缓存（模拟重启）', () async {
    final f = await _writePng(tmp, 'd.png', 800, 600, 0xFF123456);
    final mgr = ImageManager(thumbCacheDir: thumbs);
    final d1 = await mgr.decode(f.path, 7, target: 320);
    expect(d1.width <= 320 && d1.height <= 320, isTrue);
    final pngs = await thumbs
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    expect(pngs, isNotEmpty, reason: '缩略图应写入磁盘缓存');
    mgr.dispose();

    final mgr2 = ImageManager(thumbCacheDir: thumbs);
    final d2 = await mgr2.decode(f.path, 7, target: 320);
    expect(d2.fromCache, isTrue, reason: '重启后应命中磁盘缩略图缓存');
    expect(d2.srcWidth, 800, reason: '磁盘缓存命中也应携带原图固有尺寸');
    expect(d2.srcHeight, 600);
    mgr2.dispose();
  });

  test('小图不放大：target 大于原图宽时按原尺寸解码并携带源尺寸', () async {
    final f = await _writePng(tmp, 'small.png', 40, 20, 0xFF00FF00);
    final mgr = ImageManager(thumbCacheDir: thumbs);
    final d = await mgr.decode(f.path, 11, target: 512);
    expect(d.width, 40, reason: '解码器不得把小图拉伸到 target');
    expect(d.height, 20);
    expect(d.srcWidth, 40);
    expect(d.srcHeight, 20);
    // 小图跳过缩略图缓存（避免放大图入缓存）
    final pngs = await thumbs.exists()
        ? await thumbs.list().where((e) => e is File).length
        : 0;
    expect(pngs, 0, reason: '小图不应产生缩略图缓存文件');
    mgr.dispose();
  });

  test('大图降采样：位图缩到目标宽，源尺寸单独保留', () async {
    final f = await _writePng(tmp, 'big.png', 800, 600, 0xFF223344);
    final mgr = ImageManager(thumbCacheDir: thumbs);
    final d = await mgr.decode(f.path, 12, target: 200);
    expect(d.width, 200);
    expect(d.height, 150, reason: '等比缩放：800×600 → 200×150');
    expect(d.srcWidth, 800);
    expect(d.srcHeight, 600);
    expect(d.bytes, 200 * 150 * 4, reason: '字节预算按实际位图计');
    mgr.dispose();
  });

  test('clearThumbCache 清空并返回数量', () async {
    final f = await _writePng(tmp, 'e.png', 400, 300, 0xFF654321);
    final mgr = ImageManager(thumbCacheDir: thumbs);
    await mgr.decode(f.path, 9, target: 160);
    final n = await mgr.clearThumbCache();
    expect(n, greaterThanOrEqualTo(1));
    expect(await thumbs.exists(), isTrue);
    mgr.dispose();
  });
}
