// GIF 播放过快回归测试。
//
// 根因（2026-09 实测）：Flutter 引擎对 GIF 帧延时原样返回（0cs→0ms、1cs→10ms），
// 不做浏览器式钳制；viewer 页直接 Timer(info.duration) 会让 0 延时帧零间隔
// 空转，动图快放到不可看。修复：clampAnimFrameDelay 按 Chrome/Firefox 惯例
// 把 0/10ms 帧钳到 100ms。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;

import 'package:agent_image_viewer/ui/viewer/viewer_page.dart';

/// 构造帧延时可控的最小 GIF（1x1，2 色全局色表，NETSCAPE 循环）。
/// [delaysCs] 为各帧延时，单位 1/100 秒。
Uint8List _gif(List<int> delaysCs) {
  final b = BytesBuilder();
  b.add([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]); // "GIF89a"
  b.add([1, 0, 1, 0, 0x80, 0, 0]); // 逻辑屏幕 1x1，带全局色表
  b.add([0, 0, 0, 255, 255, 255]); // 全局色表 2 色
  b.add([0x21, 0xFF, 0x0B]); // 应用扩展 NETSCAPE2.0（无限循环）
  b.add('NETSCAPE2.0'.codeUnits);
  b.add([0x03, 0x01, 0x00, 0x00, 0x00]);
  for (final d in delaysCs) {
    // 图形控制扩展：延时 d 个百分之一秒
    b.add([0x21, 0xF9, 0x04, 0x00, d & 0xFF, (d >> 8) & 0xFF, 0x00, 0x00]);
    // 图像描述符：1x1，无局部色表
    b.add([0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x00]);
    // LZW 数据（minCodeSize=2，1 像素，值 0）：清码4 + 像素0 + 结束码5
    b.add([0x02, 0x02, 0x44, 0x01, 0x00]);
  }
  b.add([0x3B]); // 结束
  return b.takeBytes();
}

void main() {
  test('clampAnimFrameDelay：0/10ms 钳到 100ms，其余原样', () {
    expect(clampAnimFrameDelay(Duration.zero), const Duration(milliseconds: 100));
    expect(clampAnimFrameDelay(const Duration(milliseconds: 1)),
        const Duration(milliseconds: 100));
    expect(clampAnimFrameDelay(const Duration(milliseconds: 10)),
        const Duration(milliseconds: 100));
    expect(clampAnimFrameDelay(const Duration(milliseconds: 11)),
        const Duration(milliseconds: 11));
    expect(clampAnimFrameDelay(const Duration(milliseconds: 20)),
        const Duration(milliseconds: 20));
    expect(clampAnimFrameDelay(const Duration(milliseconds: 50)),
        const Duration(milliseconds: 50));
    expect(clampAnimFrameDelay(const Duration(seconds: 1)),
        const Duration(seconds: 1));
  });

  test('引擎行为探针：0/10/20/50ms 编码值下引擎报告的原始帧延时', () async {
    final bytes = _gif([0, 1, 2, 5]);
    final anim = im.GifDecoder().decode(bytes);
    expect(anim?.frames.length, 4, reason: '测试用 GIF 应为 4 帧');

    final codec = await ui.instantiateImageCodec(bytes);
    expect(codec.frameCount, 4);
    final reported = <int>[];
    for (var i = 0; i < codec.frameCount; i++) {
      final info = await codec.getNextFrame();
      reported.add(info.duration.inMilliseconds);
      info.image.dispose();
    }
    codec.dispose();
    // 留档：引擎不钳制 0 延时帧（若未来引擎版本开始钳制，此打印会变为
    // [100, 100, 20, 50]，届时 viewer 页的钳制可保留为幂等无害）。
    // ignore: avoid_print
    print('ENGINE_RAW_DURATIONS_MS=$reported');
    expect(reported.length, 4);
  });
}
