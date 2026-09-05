import 'package:agent_image_viewer/core/viewer/viewer_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ViewerState 缩放', () {
    test('适应窗口与实际像素', () {
      final v = ViewerState()..resetForImage(2000, 1000, 1000, 1000);
      expect(v.scale, closeTo(0.5, 1e-9)); // min(0.5, 1.0)
      expect(v.isAtFit, isTrue);
      v.actualSize();
      expect(v.scale, 1.0);
      expect(v.isAtFit, isFalse);
    });

    test('缩放上下限 25% ~ 3200%', () {
      final v = ViewerState()..resetForImage(100, 100, 1000, 1000);
      for (var i = 0; i < 30; i++) {
        v.zoomAt(2, 500, 500);
      }
      expect(v.scale, ViewerState.maxScale);
      for (var i = 0; i < 40; i++) {
        v.zoomAt(0.5, 500, 500);
      }
      expect(v.scale, ViewerState.minScale);
    });

    test('锚点缩放：锚点内容保持不动', () {
      final v = ViewerState()..resetForImage(1000, 1000, 1000, 1000);
      // 放大到 2x 后，锚点 (600, 400) 对应的图像坐标不变
      v.zoomAt(2, 600, 400);
      expect(v.scale, 2.0);
      // 锚点前：imageX = (600 - offsetX) / scale
      // zoomAt 公式保证 (fx - offsetX') / scale' == (fx - offsetX) / scale
      final imgXBefore = (600 - 0) / 1.0; // 初始 offsetX=0（图恰铺满视口）
      final imgXAfter = (600 - v.offsetX) / v.scale;
      expect(imgXAfter, closeTo(imgXBefore, 1e-6));
    });

    test('平移夹取：放大后不能拖出边界，缩小后居中', () {
      final v = ViewerState()..resetForImage(1000, 1000, 500, 500);
      v.actualSize(); // 1x，图 1000 大于视口 500
      v.pan(10000, 10000);
      expect(v.offsetX, 0, reason: '右边界夹取到 0');
      v.pan(-10000, -10000);
      expect(v.offsetX, 500 - 1000, reason: '左边界夹取到 viewportW - w');
      // 缩小到适应后，平移无效且保持居中
      v.fitWindow();
      final cx = v.offsetX;
      v.pan(100, 100);
      expect(v.offsetX, cx, reason: '图小于视口时平移被居中夹取');
    });

    test('视口尺寸变化时画布保持居中', () {
      final v = ViewerState()..resetForImage(400, 400, 1000, 1000);
      // fit = 2.5x，宽 1000，居中 offsetX = 0
      v.setViewport(1200, 1000);
      expect(v.offsetX, closeTo((1200 - 1000) / 2, 1e-6));
    });
  });

  group('ViewerNavigator', () {
    test('循环翻页', () {
      final n = ViewerNavigator(count: 3, initial: 0);
      expect(n.next(), isTrue);
      expect(n.index, 1);
      n.next();n.next();
      expect(n.index, 0, reason: '到尾部循环回头');
      expect(n.previous(), isTrue);
      expect(n.index, 2);
    });

    test('不循环翻页到头返回 false', () {
      final n = ViewerNavigator(count: 2, initial: 1);
      expect(n.next(loop: false), isFalse);
      expect(n.index, 1);
      expect(n.previous(loop: false), isTrue);
      expect(n.previous(loop: false), isFalse);
    });

    test('首尾跳转与空列表', () {
      final n = ViewerNavigator(count: 5);
      n.last();
      expect(n.index, 4);
      n.first();
      expect(n.index, 0);
      expect(ViewerNavigator(count: 0).isEmpty, isTrue);
      expect(ViewerNavigator(count: 0).index, -1);
    });
  });
}
