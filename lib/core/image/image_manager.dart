/// 解码管理器：字节预算 LRU + 缩略图磁盘缓存（设计书 3.3 节）。
///
/// 生命周期规则：
/// - 缓存按字节预算淘汰（桌面默认 512 MB），而不是按条目数；
/// - 调用方（视图）必须对正在显示的条目 pin/unpin，淘汰跳过被钉住的条目；
/// - 只有真正被淘汰的条目才 dispose 位图句柄。
library;

import 'dart:io';
import 'dart:ui' as ui;

import '../pipeline/source.dart';

class DecodedImage {
  DecodedImage(this.cacheKey, this.image, this.width, this.height,
      {this.fromCache = false});
  final String cacheKey;
  final ui.Image image;
  final int width, height;
  final bool fromCache;

  int get bytes => width * height * 4;
}

class ImageManager {
  ImageManager({
    required Directory thumbCacheDir,
    this.capacityBytes = 512 * 1024 * 1024,
  }) : _thumbs = thumbCacheDir;

  final Directory _thumbs;

  /// 解码缓存字节预算（桌面 512 MB / 移动 256 MB，可配置）。
  final int capacityBytes;

  final LruCache<String, DecodedImage> _lru =
      LruCache(capacity: 4096); // 条目数放宽，真实预算按字节
  final Map<String, int> _pins = {}; // key → 引用计数
  int _usedBytes = 0;

  int get usedBytes => _usedBytes;
  bool isPinned(String key) => _pins.containsKey(key);

  /// @visibleForTesting
  bool debugHas(String key) => _lru.keys.contains(key);

  String _key(String path, int mtimeMs, int target) =>
      '${path.hashCode.toUnsigned(32)}_${mtimeMs}_$target';

  /// 显示期间钉住条目（引用计数，可重复钉）。
  void pin(String key) => _pins[key] = (_pins[key] ?? 0) + 1;

  /// 释放显示引用；计数归零后允许淘汰。
  void unpin(String key) {
    final n = (_pins[key] ?? 0) - 1;
    if (n <= 0) {
      _pins.remove(key);
    } else {
      _pins[key] = n;
    }
  }

  /// 全量解码（target=0 原尺寸）或降采样解码（target>0，含缩略图磁盘缓存）。
  ///
  /// [autoPin] 解码/命中后立即钉住：显示方持有期间禁止淘汰释放。
  /// 必须与 unpin 成对；消除「decode 返回到调用方手动 pin 之间」的竞态淘汰窗口。
  Future<DecodedImage> decode(String path, int mtimeMs,
      {int target = 0, bool autoPin = false}) async {
    final key = _key(path, mtimeMs, target);
    final hit = _lru[key];
    if (hit != null) {
      if (autoPin) pin(key);
      return hit;
    }

    DecodedImage dec;
    if (target > 0) {
      final cached = await _thumbFromDisk(path, mtimeMs, target);
      if (cached != null) {
        dec = DecodedImage(key, cached, cached.width, cached.height,
            fromCache: true);
      } else {
        final bytes = await File(path).readAsBytes();
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: target,
          targetHeight: target,
        );
        final frame = await codec.getNextFrame();
        final img = frame.image;
        dec = DecodedImage(key, img, img.width, img.height);
        await _thumbToDisk(path, mtimeMs, target, img);
      }
    } else {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      dec = DecodedImage(key, img, img.width, img.height);
    }

    // 先注册 pin 再入缓存：防止 insert 的预算淘汰在 pin 前选中自己（插入即淘汰）
    if (autoPin) pin(key);
    _insert(dec);
    return dec;
  }

  void _insert(DecodedImage dec) {
    for (final old in _lru.put(dec.cacheKey, dec)) {
      _usedBytes -= old.bytes;
      old.image.dispose();
    }
    _usedBytes += dec.bytes;
    _evictWithinBudget();
  }

  void _evictWithinBudget() {
    while (_usedBytes > capacityBytes) {
      String? victimKey;
      for (final k in _lru.keys) {
        // keys 按最旧到最新排列
        if (!_pins.containsKey(k)) {
          victimKey = k;
          break;
        }
      }
      if (victimKey == null) break; // 全部被显示占用：允许超预算，宁大勿崩
      final victim = _lru.remove(victimKey)!;
      _usedBytes -= victim.bytes;
      victim.image.dispose();
    }
  }

  Future<ui.Image?> _thumbFromDisk(String path, int mtimeMs, int target) async {
    final f = File('${_thumbs.path}${Platform.pathSeparator}'
        '${thumbCacheKey(path, mtimeMs, target)}.png');
    if (!await f.exists()) return null;
    try {
      final codec = await ui.instantiateImageCodec(await f.readAsBytes());
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      try {
        await f.delete();
      } catch (_) {}
      return null;
    }
  }

  Future<void> _thumbToDisk(
      String path, int mtimeMs, int target, ui.Image img) async {
    try {
      await _thumbs.create(recursive: true);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      await File('${_thumbs.path}${Platform.pathSeparator}'
              '${thumbCacheKey(path, mtimeMs, target)}.png')
          .writeAsBytes(data.buffer.asUint8List(), flush: true);
    } catch (_) {/* 缓存写失败不影响主流程 */}
  }

  /// 一键重建缩略图缓存（设置页入口）。
  Future<int> clearThumbCache() async {
    var n = 0;
    if (await _thumbs.exists()) {
      await for (final e in _thumbs.list()) {
        if (e is File) {
          await e.delete();
          n++;
        }
      }
    }
    return n;
  }

  void dispose() {
    for (final v in _lru.values) {
      v.image.dispose();
    }
    _lru.clear();
    _usedBytes = 0;
    _pins.clear();
  }
}
