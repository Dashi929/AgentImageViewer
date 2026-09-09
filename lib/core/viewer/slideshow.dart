/// 幻灯片（设计书 2.2）：定时自动播放，间隔由用户自由输入（秒，可小数），
/// 支持随机顺序与循环播放。纯逻辑，可单测；计时器由 UI 层持有。
library;

import 'dart:math' as math;

/// 计算下一张幻灯片索引。
/// 返回 null 表示播放结束（非循环且到最后一张）。
/// [random] 时随机挑一个与当前不同的索引（单张图库返回 null）。
int? nextSlideIndex({
  required int current,
  required int count,
  required bool random,
  required bool loop,
  math.Random? rng,
}) {
  if (count <= 0) return null;
  if (count == 1) return loop ? 0 : null;

  if (random) {
    final r = rng ?? math.Random();
    var next = current;
    while (next == current) {
      next = r.nextInt(count);
    }
    return next;
  }

  var i = current + 1;
  if (i < count) return i;
  return loop ? 0 : null; // 顺序播放：末尾循环回头或结束
}
