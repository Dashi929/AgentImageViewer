/// 编辑器控制器：管道 + 预览求值 + 历史持久化（设计书 2.3/4.3.3）。
///
/// 非破坏性：原图字节永不修改；操作栈随编辑自动保存（中途退出不丢失）。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as imgpkg;

import '../db/json_store.dart';
import '../pipeline/node.dart';
import '../pipeline/pipeline.dart';
import '../pipeline/render.dart';

enum ExportFormat { png, jpg }

class ExportResult {
  ExportResult(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width, height;
}

class EditorController extends ChangeNotifier {
  EditorController({
    required this.imageId,
    required this.source,
    required this.store,
    ui.Image? previewSource,
  }) : previewSource = previewSource ?? source {
    _active[imageId] = this;
  }

  /// 活跃编辑器注册表（UI 事件与测试可达）。
  static final Map<String, EditorController> _active = {};

  /// @visibleForTesting
  static EditorController? controllerFor(String imageId) => _active[imageId];

  final String imageId;

  /// 全尺寸源图（导出合成用）。
  final ui.Image source;

  /// 预览源图（≤2048，滑杆实时求值用，避免大图卡顿）。
  final ui.Image previewSource;

  final JsonStore store;
  final ImagePipeline pipeline = ImagePipeline();

  ui.Image? _preview;
  String _previewHash = '';

  /// 当前预览（管线求值结果；无节点时直接复用原图）。
  ui.Image? get preview => _preview;
  bool get dirty => pipeline.toJson().isNotEmpty;

  /// 加载持久化的操作栈（进入编辑时调用）。
  Future<void> loadStack() async {
    final data = await store.loadEditStack(imageId);
    if (data != null) {
      try {
        pipeline.reset(
          [for (final op in (data['ops'] as List? ?? [])) FilterNode.fromJson((op as Map).cast<String, Object?>())],
        );
      } catch (_) {
        pipeline.reset(null); // 栈损坏按无编辑处理，不阻塞打开
      }
    }
  }

  Future<void> saveStack() async {
    await store.saveEditStack(imageId, pipeline.toJson());
  }

  Future<void> addNode(FilterNode node) async {
    pipeline.add(node);
    notifyListeners();
    await saveStack();
  }

  Future<void> undo() async {
    if (pipeline.undo()) {
      notifyListeners();
      await saveStack();
    }
  }

  Future<void> redo() async {
    if (pipeline.redo()) {
      notifyListeners();
      await saveStack();
    }
  }

  Future<void> resetAll() async {
    pipeline.reset(null);
    notifyListeners();
    await saveStack();
  }

  /// 重算预览：管线未变则跳过；返回是否实际重算。
  Future<bool> recomputePreview() async {
    // Map.hashCode 是身份哈希：toJson 每次 new Map 会恒变，
    // 必须用内容稳定的字符串做去重指纹
    final hash = pipeline.nodes.map((n) => n.toJson().toString()).join('|');
    if (hash == _previewHash && _preview != null) return false;
    _previewHash = hash;
    try {
      _preview = pipeline.nodes.isEmpty
          ? previewSource
          : await renderPipeline(previewSource, pipeline.nodes);
    } catch (_) {
      return false; // 渲染失败保持旧预览，不让 UI 线程崩掉
    }
    notifyListeners();
    return true;
  }

  /// 导出合成：整栈一次性求值到目标像素（设计书 2.3）。
  /// JPG 质量参数 60~100；WebP 导出经 JPG 编码降级（image 包不支持 WebP 编码）。
  Future<ExportResult> exportBytes(ExportFormat fmt, {int quality = 90}) async {
    final out = pipeline.nodes.isEmpty
        ? source
        : await renderPipeline(source, pipeline.nodes);
    if (fmt == ExportFormat.png) {
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      return ExportResult(data!.buffer.asUint8List(), out.width, out.height);
    }
    final q = quality.clamp(60, 100).toInt();
    final rgba = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
    final im = imgpkg.Image.fromBytes(
      width: out.width,
      height: out.height,
      bytes: rgba!.buffer,
      numChannels: 4,
    );
    return ExportResult(
        Uint8List.fromList(imgpkg.encodeJpg(im, quality: q)), out.width, out.height);
  }

  /// 导出落盘：另存副本 / 覆盖原文件（确认 + .bak 备份由 UI 层决定，本层只写）。
  Future<void> writeFile(String path, List<int> bytes) async {
    final f = File(path);
    if (await f.exists()) {
      await File('$path.bak').writeAsBytes(await f.readAsBytes(), flush: true);
    }
    await f.writeAsBytes(bytes, flush: true);
  }

  @override
  void dispose() {
    _active.remove(imageId);
    if (_preview != null && _preview != previewSource) _preview!.dispose();
    super.dispose();
  }
}
