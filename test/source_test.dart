import 'package:agent_image_viewer/core/pipeline/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tile 分块规划', () {
    test('可见区域只产生相交 tile，边界块自动截断', () {
      final tiles = planTiles(
        imageWidth: 1000,
        imageHeight: 700,
        tileSize: 256,
        viewLeft: 200,
        viewTop: 100,
        viewRight: 600,
        viewBottom: 700, // 视口触到图像底边
      );
      // x 方向覆盖列 0(0..256) 列1(256..512) 列2(512..768)
      // y 方向覆盖行 0(0..256) 行1(256..512) 行2(512..700，被截断为 188 高)
      expect(tiles.length, 3 * 3);
      expect(tiles.first, const TileRect(0, 0, 256, 256));
      expect(tiles.contains(const TileRect(512, 512, 256, 188)), isTrue,
          reason: '底部块高度被截断到 700-512=188');
      expect(tiles.every((t) => t.h > 0 && t.w > 0), isTrue);
    });

    test('视口越界被 clamp，空视口返回空', () {
      expect(
        planTiles(
            imageWidth: 100,
            imageHeight: 100,
            tileSize: 64,
            viewLeft: -50,
            viewTop: -50,
            viewRight: 10,
            viewBottom: 10),
        isNotEmpty,
      );
      expect(
        planTiles(
            imageWidth: 100,
            imageHeight: 100,
            tileSize: 64,
            viewLeft: 300,
            viewTop: 300,
            viewRight: 400,
            viewBottom: 400),
        isEmpty,
      );
    });

    test('非法尺寸返回空', () {
      expect(
        planTiles(
            imageWidth: 0,
            imageHeight: 0,
            tileSize: 256,
            viewLeft: 0,
            viewTop: 0,
            viewRight: 10,
            viewBottom: 10),
        isEmpty,
      );
    });
  });

  group('LRU 缓存', () {
    test('超容按最近最少使用淘汰并返回被淘汰项', () {
      final c = LruCache<String, int>(capacity: 2);
      c.put('a', 1);
      c.put('b', 2);
      c['a']; // 触碰 a，b 变为最旧
      final evicted = c.put('c', 3);
      expect(evicted, [2]);
      expect(c['b'], isNull);
      expect(c['a'], 1);
      expect(c['c'], 3);
    });

    test('重复 put 同 key 不扩容', () {
      final c = LruCache<String, int>(capacity: 2);
      c.put('a', 1);
      c.put('a', 9);
      expect(c.length, 1);
      expect(c['a'], 9);
    });

    test('容量必须为正', () {
      expect(() => LruCache<String, int>(capacity: 0), throwsArgumentError);
    });
  });

  test('缩略图缓存键包含路径、mtime 与尺寸', () {
    final k1 = thumbCacheKey(r'E:\pics\a.jpg', 1000, 320);
    final k2 = thumbCacheKey(r'E:\pics\b.jpg', 1000, 320);
    final k3 = thumbCacheKey(r'E:\pics\a.jpg', 2000, 320);
    final k4 = thumbCacheKey(r'E:\pics\a.jpg', 1000, 160);
    expect(k1, isNot(k2));
    expect(k1, isNot(k3));
    expect(k1, isNot(k4));
    expect(thumbCacheKey(r'E:\pics\a.jpg', 1000, 320), k1, reason: '同输入键稳定');
  });
}
