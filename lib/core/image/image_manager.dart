/// 解码管理器：字节预算 LRU + 缩略图磁盘缓存（设计书 3.3 节）。
///
/// 生命周期规则：
/// - 缓存按字节预算淘汰（桌面默认 512 MB），而不是按条目数；
/// - 调用方（视图）必须对正在显示的条目 pin/unpin，淘汰跳过被钉住的条目；
/// - 只有真正被淘汰的条目才 dispose 位图句柄。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../pipeline/source.dart';

class DecodedImage {
  DecodedImage(this.cacheKey, this.image, this.width, this.height,
      {this.fromCache = false, this.srcWidth, this.srcHeight});
  final String cacheKey;
  final ui.Image image;
  final int width, height;

  /// 原图固有尺寸（可解析时提供）：缩放百分比语义与条目元数据以此为准，
  /// 与 [width]/[height]（实际位图尺寸，降采样后更小）区分。
  final int? srcWidth, srcHeight;

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

  /// 显示解码（设计书 3.3）：target=0 全量解码；target>0 等比缩到宽 [target]。
  ///
  /// **只缩不放大**：原图宽不大于 [target] 时按原尺寸解码并跳过缩略图缓存
  /// （杜绝解码器 targetWidth 把小图强制拉伸——曾致元数据显示 2024×1518、
  /// 「100% 实际大小」实为放大图，2026-09-09 用户反馈）。
  /// [DecodedImage.srcWidth]/[srcHeight] 携带原图固有尺寸。
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
      final src = await _intrinsicSize(path);
      final srcW = src?.$1;
      final srcH = src?.$2;
      if (srcW != null && srcW <= target) {
        // 原图不大于目标：按原尺寸解码，跳过缩略图缓存（避免放大图入缓存）
        final img = await _decodeCodec(path, null);
        dec = DecodedImage(key, img, img.width, img.height,
            srcWidth: srcW, srcHeight: srcH);
      } else {
        final cached = await _thumbFromDisk(path, mtimeMs, target);
        if (cached != null) {
          dec = DecodedImage(key, cached, cached.width, cached.height,
              fromCache: true, srcWidth: srcW, srcHeight: srcH);
        } else {
          final img = await _decodeCodec(path, target);
          dec = DecodedImage(key, img, img.width, img.height,
              srcWidth: srcW, srcHeight: srcH);
          await _thumbToDisk(path, mtimeMs, target, img);
        }
      }
    } else {
      final img = await _decodeCodec(path, null);
      dec = DecodedImage(key, img, img.width, img.height);
    }

    // 先注册 pin 再入缓存：防止 insert 的预算淘汰在 pin 前选中自己（插入即淘汰）
    if (autoPin) pin(key);
    _insert(dec);
    return dec;
  }

  /// 原图固有尺寸（只解析文件头，不整图解码）；失败返回 null。
  Future<(int, int)?> _intrinsicSize(String path) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = (descriptor.width, descriptor.height);
      descriptor.dispose();
      buffer.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }

  /// 解码单帧。[targetWidth] 非空时等比缩到该宽（调用方保证小于原图宽，
  /// 此处不放大）。走 ImageDescriptor 管线；异常时退回 instantiateImageCodec
  /// 直解（动图等 descriptor 支持不稳场景的兜底，行为同旧版）。
  ///
  /// 注意：descriptor/buffer 必须在 getNextFrame 完成后再 dispose——
  /// codec 取帧仍引用其原生数据，提前释放会在真实引擎上挂死
  ///（flutter_test 软件引擎不触发，集成测试抓到，2026-09-09）。
  Future<ui.Image> _decodeCodec(String path, int? targetWidth) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final downscale =
          targetWidth != null && targetWidth < descriptor.width;
      final codec = await descriptor.instantiateCodec(
        targetWidth: downscale ? targetWidth : null,
      );
      final intrinsic = (descriptor.width, descriptor.height);
      final frame = await codec.getNextFrame();
      descriptor.dispose();
      buffer.dispose();
      if (downscale && frame.image.width >= intrinsic.$1) {
        frame.image.dispose();
        throw StateError('downscale did not apply');
      }
      return frame.image;
    } catch (_) {
      final bytes = await File(path).readAsBytes();
      final codec = targetWidth == null
          ? await ui.instantiateImageCodec(bytes)
          : await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
      final frame = await codec.getNextFrame();
      return frame.image;
    }
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

  /// 把位图重建为 software 位图（像素可被 toImageSync 离屏画布读取）。
  /// Android/Windows 解码器默认 hardware 位图，绘制进 toImageSync 画布会画黑。
  static Future<ui.Image> toSoftwareImage(ui.Image img) async {
    final data =
        await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return img;
    final buffer = Uint8List.view(data.buffer);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      buffer,
      img.width,
      img.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
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
