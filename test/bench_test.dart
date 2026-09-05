import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_image_viewer/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';

/// 性能基准（设计书 3.3 验收口径）——仅在设置 AIV_BENCH=1 时运行：
///   python tool/gen_bench_images.py
///   AIV_BENCH=1 flutter test test/bench_test.dart
///
/// 不进 CI：绝对耗时受机器/编译模式影响，作为本地验收口径。
void main() {
  final enabled = Platform.environment['AIV_BENCH'] == '1';
  final root = Directory('bench');

  test('万张文件夹扫描基准（10000 张）', () async {
    if (!enabled) return;
    final many = Directory('bench/many');
    if (!many.existsSync()) return;
    final sw = Stopwatch()..start();
    final entries = await scanDirectory(many.path, depth: 1);
    sw.stop();
    // ignore: avoid_print
    print('[bench] scan ${entries.length} files: ${sw.elapsedMilliseconds}ms');
    expect(entries.length, greaterThanOrEqualTo(10000));
    expect(sw.elapsedMilliseconds, lessThan(60000), reason: '万张扫描不应阻塞界面（宽松上限，release 下应远快于此）');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('亿像素大图解码首帧基准（12000x9000 → 1080 预览）', () async {
    if (!enabled) return;
    final f = File('bench/huge.jpg');
    if (!f.existsSync()) return;
    final bytes = await f.readAsBytes();
    final sw = Stopwatch()..start();
    final codec =
        await ui.instantiateImageCodec(bytes, targetWidth: 1080, targetHeight: 1080);
    final frame = await codec.getNextFrame();
    sw.stop();
    // ignore: avoid_print
    print('[bench] huge first frame ${frame.image.width}x'
        '${frame.image.height}: ${sw.elapsedMilliseconds}ms');
    frame.image.dispose();
    expect(sw.elapsedMilliseconds, lessThan(30000),
        reason: '亿像素降采样首帧（宽松上限，release 下应远快于此）');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('样张存在性自检（bench 模式下）', () {
    if (!enabled) return;
    expect(root.existsSync(), isTrue, reason: '先运行 python tool/gen_bench_images.py');
  });
}
