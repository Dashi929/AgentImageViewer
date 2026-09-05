/// 浏览视图状态机（纯逻辑，可单测）：缩放/平移/翻页/适应窗口（设计书 2.2 节）。
library;

import 'dart:math' as math;

class ViewerState {
  ViewerState({
    this.scale = 1.0,
    this.offsetX = 0,
    this.offsetY = 0,
    this.imageWidth = 0,
    this.imageHeight = 0,
    this.viewportW = 1,
    this.viewportH = 1,
  });

  static const minScale = 0.25; // 设计书：25%
  static const maxScale = 32.0; // 设计书：3200%

  double scale;
  double offsetX, offsetY; // 画布左上角相对视口的位移（像素）
  int imageWidth, imageHeight;
  double viewportW, viewportH;

  /// 打开新图：适应窗口居中。
  void resetForImage(int w, int h, double vw, double vh) {
    imageWidth = w;
    imageHeight = h;
    viewportW = vw;
    viewportH = vh;
    fitWindow();
  }

  void setViewport(double vw, double vh) {
    if (vw <= 0 || vh <= 0) return;
    final dw = vw - viewportW, dh = vh - viewportH;
    viewportW = vw;
    viewportH = vh;
    offsetX += dw / 2;
    offsetY += dh / 2;
    _clampOffset();
  }

  /// 适应窗口。
  void fitWindow() {
    if (imageWidth == 0 || imageHeight == 0) return;
    final sx = viewportW / imageWidth, sy = viewportH / imageHeight;
    scale = _clampScale(math.min(sx, sy));
    center();
  }

  /// 100% 实际像素。
  void actualSize() {
    scale = 1.0;
    center();
  }

  void center() {
    offsetX = (viewportW - imageWidth * scale) / 2;
    offsetY = (viewportH - imageHeight * scale) / 2;
    _clampOffset();
  }

  /// 以视口坐标 (fx, fy) 为锚点缩放 [factor] 倍，锚点内容保持不动。
  void zoomAt(double factor, double fx, double fy) {
    final ns = _clampScale(scale * factor);
    if (ns == scale) return;
    final ratio = ns / scale;
    offsetX = fx - (fx - offsetX) * ratio;
    offsetY = fy - (fy - offsetY) * ratio;
    scale = ns;
    _clampOffset();
  }

  /// 平移 delta 后夹取边界（图小于视口时居中）。
  void pan(double dx, double dy) {
    offsetX += dx;
    offsetY += dy;
    _clampOffset();
  }

  bool get isAtFit {
    if (imageWidth == 0 || imageHeight == 0) return true;
    final fit = math.min(viewportW / imageWidth, viewportH / imageHeight);
    return (scale - fit).abs() < 1e-6;
  }

  double _clampScale(double s) => s.clamp(minScale, maxScale).toDouble();

  void _clampOffset() {
    final w = imageWidth * scale, h = imageHeight * scale;
    if (w <= viewportW) {
      offsetX = (viewportW - w) / 2;
    } else {
      offsetX = offsetX.clamp(viewportW - w, 0).toDouble();
    }
    if (h <= viewportH) {
      offsetY = (viewportH - h) / 2;
    } else {
      offsetY = offsetY.clamp(viewportH - h, 0).toDouble();
    }
  }
}

/// 连拍导航：同文件夹内循环与否由调用方决定，这里只做索引逻辑。
class ViewerNavigator {
  ViewerNavigator({required int count, int initial = 0})
      : _count = count,
        index = count > 0 ? initial.clamp(0, count - 1) : -1;

  final int _count;
  int index;

  int get count => _count;
  bool get isEmpty => _count == 0;

  /// 返回是否发生了移动（false 表示到头）。
  bool next({bool loop = true}) => _move(1, loop);
  bool previous({bool loop = true}) => _move(-1, loop);

  bool _move(int delta, bool loop) {
    if (_count == 0) return false;
    var i = index + delta;
    if (i < 0) {
      if (!loop) return false;
      i = _count - 1;
    } else if (i >= _count) {
      if (!loop) return false;
      i = 0;
    }
    index = i;
    return true;
  }

  void first() => index = _count > 0 ? 0 : -1;
  void last() => index = _count - 1;
}
