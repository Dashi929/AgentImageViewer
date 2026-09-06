/// 编辑器控制器：管道 + 预览求值（设计书 2.3/4.3.3）。
///
/// 非破坏性：原图字节永不修改；编辑历史仅存于内存，退出编辑即丢弃
/// （需要保留结果请导出）。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as imgpkg;

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
  EditorController({required this.imageId, required this.source}) {
    _active[imageId] = this;
  }

  /// 活跃编辑器注册表（UI 事件与测试可达）。
  static final Map<String, EditorController> _active = {};

  /// @visibleForTesting
  static EditorController? controllerFor(String imageId) => _active[imageId];

  /// @visibleForTesting
  static Map<String, EditorController> get activeControllers => _active;

  final String imageId;

  /// 全尺寸源图（屏幕直绘与导出合成用）。
  final ui.Image source;

  final ImagePipeline pipeline = ImagePipeline();

  /// 预览代数：节点/历史每次变化 +1，驱动画布 painter 重绘。
  int generation = 0;
  bool get dirty => pipeline.toJson().isNotEmpty;

  Future<void> addNode(FilterNode node) async {
    pipeline.add(node);
    generation++;
    notifyListeners();
  }

  Future<void> undo() async {
    if (pipeline.undo()) {
      generation++;
      notifyListeners();
    }
  }

  Future<void> redo() async {
    if (pipeline.redo()) {
      generation++;
      notifyListeners();
    }
  }

  Future<void> resetAll() async {
    pipeline.reset(null);
    generation++;
    notifyListeners();
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
    super.dispose();
  }
}
