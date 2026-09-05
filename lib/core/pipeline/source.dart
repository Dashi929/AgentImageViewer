/// Source 层纯逻辑：缩略图缓存键、tile 分块规划、LRU 解码缓存。
///
/// 与运行环境解耦：解码由 UI/平台层执行，本模块只做决策。
library;



/// 磁盘缩略图缓存键：`路径哈希 + mtime + 目标尺寸`（设计书 3.3 节）。
String thumbCacheKey(String path, int mtimeMs, int targetSize) {
  final h = path.hashCode.toUnsigned(32).toRadixString(16);
  return 't_${h}_$mtimeMs _$targetSize'.replaceAll(' ', '_');
}

/// 可见区域的 tile 规划：把整图切成 size×size 的块，
/// 返回与可见区域相交的块矩形（原图像素坐标）。
class TileRect {
  const TileRect(this.x, this.y, this.w, this.h);
  final int x, y, w, h;

  @override
  bool operator ==(Object other) =>
      other is TileRect && other.x == x && other.y == y && other.w == w && other.h == h;
  @override
  int get hashCode => Object.hash(x, y, w, h);
  @override
  String toString() => 'Tile($x,$y,$w,$h)';
}

List<TileRect> planTiles({
  required int imageWidth,
  required int imageHeight,
  required int tileSize,
  required int viewLeft,
  required int viewTop,
  required int viewRight,
  required int viewBottom,
}) {
  if (imageWidth <= 0 || imageHeight <= 0) return const [];
  if (tileSize <= 0) return const [];
  final l = viewLeft.clamp(0, imageWidth);
  final t = viewTop.clamp(0, imageHeight);
  final r = viewRight.clamp(l, imageWidth);
  final b = viewBottom.clamp(t, imageHeight);
  if (r <= l || b <= t) return const [];

  final out = <TileRect>[];
  final x0 = l ~/ tileSize, x1 = (r - 1) ~/ tileSize;
  final y0 = t ~/ tileSize, y1 = (b - 1) ~/ tileSize;
  for (var ty = y0; ty <= y1; ty++) {
    for (var tx = x0; tx <= x1; tx++) {
      final px = tx * tileSize, py = ty * tileSize;
      out.add(TileRect(
        px,
        py,
        (px + tileSize).clamp(0, imageWidth) - px,
        (py + tileSize).clamp(0, imageHeight) - py,
      ));
    }
  }
  return out;
}

/// LRU 缓存：容量按条目数限制（内存字节估算由调用方传入权重）。
class LruCache<K, V> {
  LruCache({required int capacity}) : _capacity = capacity {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity', '必须 > 0');
  }

  final int _capacity;
  final _map = <K, V>{};

  int get length => _map.length;
  V? operator [](K key) {
    final v = _map.remove(key);
    if (v != null) _map[key] = v; // 触碰即置新
    return v;
  }

  /// 淘汰的条目返回给调用方（用于显式释放位图句柄）。
  List<V> put(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    final evicted = <V>[];
    while (_map.length > _capacity) {
      final k = _map.keys.first;
      final v = _map.remove(k);
      if (v != null) evicted.add(v);
    }
    return evicted;
  }

  V? remove(K key) => _map.remove(key);
  void clear() => _map.clear();

  Iterable<K> get keys => _map.keys;
  Iterable<V> get values => _map.values;
}
