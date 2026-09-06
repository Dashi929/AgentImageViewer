/// 编辑视图（设计书 4.3.3）：中央画布 + 左侧工具箱 + 右侧属性面板。
///
/// 非破坏性：所有操作进操作栈；历史仅存于内存，退出编辑即丢弃（需保留请导出）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../core/editor/editor_controller.dart';
import '../../core/image/image_manager.dart';
import '../../core/pipeline/node.dart';
import '../../core/pipeline/preview_painter.dart';
import 'dart:ui' as ui;

import '../../core/pipeline/render.dart';
import '../../core/scanner.dart';
import '../theme.dart';

enum _Tool { crop, adjust, preset, annotate, resize }

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.entry});

  final ImageEntry entry;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  AppState? _appRef;
  EditorController? _controller;
  _Tool _tool = _Tool.adjust;
  String _annotateKind = AnnotateKinds.rect;
  String? _pinnedSourceKey; // 源图钉住：编辑期间禁止 LRU 淘汰释放
  String? _pinnedPreviewKey;

  // 裁剪/标注的拖拽状态（画布坐标，导出时换算相对比例）
  Offset? _dragStart;
  Offset? _dragNow;
  final List<Offset> _doodlePts = [];
  final _cropKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _initController();
  }

  Future<void> _initController() async {
    final app = AppStateScope.of(context, listen: false);
    _appRef = app;
    // 源图（导出用全尺寸）+ 预览图（≤2048，滑杆实时求值不卡）
    final decoded = await app.images
        .decode(widget.entry.path, widget.entry.mtimeMs, autoPin: true);
    if (!mounted) return;
    _pinnedSourceKey = decoded.cacheKey;
    // 关键：重建为 software 位图——CustomPaint.drawImage 对解码器产出的
    // GPU 位图在 Impeller(Windows/Android) 上绘制失败(灰/黑画布)，
    // 而 RawImage 路径正常；CPU 位图两条路径都正常。
    final softwareSource =
        await ImageManager.toSoftwareImage(decoded.image);
    if (!mounted) return;

    final id = widget.entry.path.hashCode.toUnsigned(32).toString();
    final ctrl = EditorController(
      imageId: id,
      source: softwareSource,
    );
    if (!mounted) return;
    setState(() => _controller = ctrl);
  }

  @override
  void dispose() {
    _controller?.dispose();
    final app = _appRef;
    final k1 = _pinnedSourceKey;
    if (k1 != null) app?.images.unpin(k1);
    final k2 = _pinnedPreviewKey;
    if (k2 != null) app?.images.unpin(k2);
    super.dispose();
  }

  // ---------- 节点提交 ----------

  void _addNode(FilterNode n) {
    _controller?.addNode(n);
  }

  void _addRotate(int deg) => _addNode(FilterNode(op: Ops.rotate, params: {'deg': deg}));

  /// 自由旋转（设计书 表 2-3：任意角度，包围盒扩展）
  void _commitFreeRotate(double deg) =>
      _addNode(FilterNode(op: Ops.freeRotate, params: {'deg': deg}));
  void _addFlip(String axis) => _addNode(FilterNode(op: Ops.flip, params: {'axis': axis}));

  void _commitAdjust(Map<String, double> params) {
    if (params.isEmpty) return;
    _addNode(FilterNode(op: Ops.adjust, params: params));
  }

  void _commitPreset(String name) => _addNode(FilterNode(op: Ops.preset, params: {'name': name}));

  void _commitResize(int? w, int? h) {
    if (w == null && h == null) return;
    final params = <String, Object?>{};
    if (w != null) params['width'] = w;
    if (h != null) params['height'] = h;
    _addNode(FilterNode(op: Ops.resize, params: params));
  }

  // ---------- 导出 ----------

  Future<void> _export() async {
    final ctrl = _controller!;
    bool overwrite = false;
    ExportFormat fmt = ExportFormat.png;
    double quality = 90;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: const Text('导出'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<ExportFormat>(
                segments: const [
                  ButtonSegment(value: ExportFormat.png, label: Text('PNG')),
                  ButtonSegment(value: ExportFormat.jpg, label: Text('JPG')),
                ],
                selected: {fmt},
                onSelectionChanged: (s) => setD(() => fmt = s.first),
              ),
              if (fmt == ExportFormat.jpg) ...[
                Text('质量 ${quality.round()}'),
                Slider(
                  value: quality,
                  min: 60,
                  max: 100,
                  divisions: 40,
                  label: quality.round().toString(),
                  onChanged: (v) => setD(() => quality = v),
                ),
              ],
              CheckboxListTile(
                value: overwrite,
                onChanged: (v) => setD(() => overwrite = v ?? false),
                title: const Text('覆盖原文件'),
                subtitle: const Text('覆盖前自动保留 .bak 备份'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                style: overwrite
                    ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
                    : null,
                onPressed: () => Navigator.pop(context, true),
                child: Text(overwrite ? '覆盖原文件' : '另存副本')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final result = await ctrl.exportBytes(fmt, quality: quality.round());
    final ext = fmt == ExportFormat.png ? 'png' : 'jpg';
    final base = widget.entry.name.substring(0, widget.entry.name.lastIndexOf('.'));
    final path = overwrite
        ? widget.entry.path
        : '${widget.entry.path.substring(0, widget.entry.path.lastIndexOf('.'))}_edited.$ext';
    await ctrl.writeFile(path, result.bytes);
    if (mounted) {
      _showOsd(overwrite ? '已覆盖原文件（.bak 已备份）' : '已导出：$base"_"edited.$ext');
    }
  }

  void _showOsd(String text) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.overlay,
        content: Text(text, style: const TextStyle(fontSize: 13)),
      ));
  }

  // ---------- 画布交互 ----------

  void _onDragStart(Offset local, Size canvasSize, ({int w, int h}) imgSize) {
    if (_tool == _Tool.crop || _tool == _Tool.annotate) {
      _dragStart = local;
      _dragNow = local;
    }
  }

  void _onDragUpdate(Offset local) {
    if (_dragStart == null) return;
    _dragNow = local;
    if (_tool == _Tool.annotate && _annotateKind == AnnotateKinds.doodle) {
      _doodlePts.add(local);
    }
    setState(() {});
  }

  void _onDragEnd(Size canvasSize, ({int w, int h}) imgSize) {
    final s = _dragStart, e = _dragNow;
    _dragStart = null;
    _dragNow = null;
    if (s == null || e == null) return;

    double rx(double px) => (px / canvasSize.width).clamp(0, 1);
    double ry(double py) => (py / canvasSize.height).clamp(0, 1);

    if (_tool == _Tool.crop) {
      final left = math.min(rx(s.dx), rx(e.dx));
      final right = math.max(rx(s.dx), rx(e.dx));
      final top = math.min(ry(s.dy), ry(e.dy));
      final bottom = math.max(ry(s.dy), ry(e.dy));
      if (right - left > 0.02 && bottom - top > 0.02) {
        _addNode(FilterNode(op: Ops.crop, params: {
          'x': left,
          'y': top,
          'w': right - left,
          'h': bottom - top,
        }));
      }
    } else if (_tool == _Tool.annotate) {
      switch (_annotateKind) {
        case AnnotateKinds.text:
          _promptText().then((text) {
            if (text != null && text.isNotEmpty) {
              _addNode(FilterNode(op: Ops.annotate, params: {
                'kind': AnnotateKinds.text,
                'text': text,
                'x': rx(e.dx),
                'y': ry(e.dy),
                'size': 32,
              }));
            }
            setState(() {});
          });
        case AnnotateKinds.doodle:
          if (_doodlePts.length > 1) {
            _addNode(FilterNode(op: Ops.annotate, params: {
              'kind': AnnotateKinds.doodle,
              'points': [
                for (final p in _doodlePts)
                  {'x': rx(p.dx), 'y': ry(p.dy)}
              ],
            }));
          }
          _doodlePts.clear();
        default:
          _addNode(FilterNode(op: Ops.annotate, params: {
            'kind': _annotateKind,
            'x': rx(s.dx),
            'y': ry(s.dy),
            'x2': rx(e.dx),
            'y2': ry(e.dy),
          }));
      }
    }
    setState(() {});
  }

  Future<String?> _promptText() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加文字标注'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('确定')),
        ],
      ),
    );
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;
    if (ctrl == null) {
      return const Scaffold(
          backgroundColor: AppColors.mainBg,
          body: Center(
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)));
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            NavigatorStateEx.editor.value = null,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): ctrl.undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): ctrl.redo,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _export,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: AppColors.mainBg,
          body: ListenableBuilder(
            listenable: ctrl,
            builder: (context, _) {
              // 窄屏（手机竖屏）：画布优先，工具与属性移到底部（设计书 4.5）
              final wide = MediaQuery.of(context).size.width >= 620;
              if (wide) {
                return Column(
                  children: [
                    _topBar(ctrl),
                    const Divider(height: 1),
                    Expanded(
                      child: Row(
                        children: [
                          _toolbox(ctrl),
                          const VerticalDivider(width: 1),
                          Expanded(child: _canvas(ctrl)),
                          const VerticalDivider(width: 1),
                          _propsPanel(ctrl),
                        ],
                      ),
                    ),
                  ],
                );
              }
              return Column(
                children: [
                  _topBar(ctrl),
                  const Divider(height: 1),
                  Expanded(child: _canvas(ctrl)),
                  const Divider(height: 1),
                  SizedBox(
                    height: 168,
                    child: SingleChildScrollView(
                      child: _propsPanel(ctrl, wide: false),
                    ),
                  ),
                  const Divider(height: 1),
                  SizedBox(
                    height: 64,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: _toolboxItems(ctrl)),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _topBar(EditorController ctrl) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            onPressed: () => NavigatorStateEx.editor.value = null,
            icon: const Icon(Icons.arrow_back, size: 20),
            tooltip: '退出编辑 (Esc)',
          ),
          Expanded(
            child: Text('编辑 · ${widget.entry.displayName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
          IconButton(
              onPressed: ctrl.pipeline.canUndo ? ctrl.undo : null,
              icon: const Icon(Icons.undo, size: 20),
              tooltip: '撤销 (Ctrl+Z)'),
          IconButton(
              onPressed: ctrl.pipeline.canRedo ? ctrl.redo : null,
              icon: const Icon(Icons.redo, size: 20),
              tooltip: '重做 (Ctrl+Y)'),
          _CompareButton(source: ctrl.source),
          IconButton(
              onPressed: ctrl.dirty ? ctrl.resetAll : null,
              icon: const Icon(Icons.restart_alt, size: 20),
              tooltip: '重置为原图'),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _export,
            icon: const Icon(Icons.ios_share, size: 16),
            label: const Text('导出'),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  List<Widget> _toolboxItems(EditorController ctrl) {
    Widget toolBtn(_Tool t, IconData icon, String label) {
      final selected = _tool == t;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Tooltip(
          message: label,
          child: InkWell(
            onTap: () => setState(() => _tool = t),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 56,
              height: 52,
              decoration: BoxDecoration(
                color: selected ? AppColors.accent.withValues(alpha: 0.15) : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon,
                      size: 20,
                      color: selected ? AppColors.accent : AppColors.textSecondary),
                  const SizedBox(height: 3),
                  Text(label,
                      style: TextStyle(
                          fontSize: 10,
                          color:
                              selected ? AppColors.accent : AppColors.textSecondary)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return [
      toolBtn(_Tool.crop, Icons.crop, '裁剪'),
      toolBtn(_Tool.adjust, Icons.tune, '调整'),
      toolBtn(_Tool.preset, Icons.filter_vintage, '滤镜'),
      toolBtn(_Tool.annotate, Icons.edit, '标注'),
      toolBtn(_Tool.resize, Icons.photo_size_select_large, '尺寸'),
    ];
  }

  Widget _toolbox(EditorController ctrl) {
    return Container(
      width: 68,
      color: AppColors.panel,
      child: Column(
        children: [
          const SizedBox(height: 8),
          ..._toolboxItems(ctrl),
        ],
      ),
    );
  }

  Widget _canvas(EditorController ctrl) {
    return LayoutBuilder(builder: (context, box) {
      final canvas = box.biggest;
      final out = sizeAfter(ctrl.pipeline.nodes, ctrl.source.width, ctrl.source.height);
      final fit = math.min(canvas.width / out.w, canvas.height / out.h);
      final drawW = out.w * fit;
      final drawH = out.h * fit;
      final topLeft = Offset((canvas.width - drawW) / 2, (canvas.height - drawH) / 2);

      // 求值前尺寸（拖拽覆盖层用原图坐标系）
      final imgSize = sizeAfter(const [], ctrl.source.width, ctrl.source.height);

      return GestureDetector(
        onTapDown: (_) {},
        onPanStart: (d) => _onDragStart(d.localPosition - topLeft, canvas, imgSize),
        onPanUpdate: (d) => _onDragUpdate(d.localPosition - topLeft),
        onPanEnd: (_) => _onDragEnd(Size(drawW, drawH), imgSize),
        child: Stack(
          children: [
            Center(
              // 屏幕直绘：源位图 + 节点矢量叠加。
              // 颜色调整/滤镜经 widget 层 ColorFiltered（Impeller 的
              // drawImage+ColorFilter 不生效）；标注矢量在滤镜内侧绘制后
              // 一并被调色，与导出顺序略有差异（可接受，已注释）。
              child: Builder(builder: (context) {
                final merged = mergedAdjustOf(ctrl.pipeline.nodes);
                final filter = adjustColorFilter(merged);
                final paintLayer = CustomPaint(
                  size: Size(drawW, drawH),
                  painter: EditorPreviewPainter(
                      source: ctrl.source,
                      nodes: ctrl.pipeline.nodes,
                      generation: ctrl.generation),
                );
                if (filter == null) return paintLayer;
                return ColorFiltered(
                    colorFilter: filter, child: paintLayer);
              }),
            ),
            // 透明棋盘格底（4.3.3）：由画布背景承担
            if (_dragStart != null && _dragNow != null) _dragOverlay(topLeft, drawW, drawH),
          ],
        ),
      );
    });
  }

  Widget _dragOverlay(Offset topLeft, double drawW, double drawH) {
    final a = _dragStart! + topLeft;
    final b = _dragNow! + topLeft;
    final rect = Rect.fromPoints(a, b);
    final isCrop = _tool == _Tool.crop;
    return Positioned.fromRect(
      rect: rect,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
              color: isCrop ? AppColors.accent : AppColors.danger, width: 1.5),
          color: isCrop
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.transparent,
        ),
      ),
    );
  }

  Widget _propsPanel(EditorController ctrl, {bool wide = true}) {
    return Container(
      width: wide ? 240 : double.infinity,
      color: AppColors.panel,
      padding: const EdgeInsets.all(14),
      child: switch (_tool) {
        _Tool.crop => _cropProps(),
        _Tool.adjust => _adjustProps(),
        _Tool.preset => _presetProps(),
        _Tool.annotate => _annotateProps(),
        _Tool.resize => _resizeProps(),
      },
    );
  }

  Widget _panelTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(t, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      );

  Widget _cropProps() {
    final src = _controller!.source;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelTitle('几何'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(onPressed: () => _addRotate(90), child: const Text('旋转 90°')),
            OutlinedButton(onPressed: () => _addRotate(-90), child: const Text('旋转 -90°')),
            OutlinedButton(onPressed: () => _addRotate(180), child: const Text('旋转 180°')),
            OutlinedButton(onPressed: () => _addFlip('h'), child: const Text('水平镜像')),
            OutlinedButton(onPressed: () => _addFlip('v'), child: const Text('垂直翻转')),
          ],
        ),
        const SizedBox(height: 10),
        const Text('自由旋转',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _FreeRotateControl(onApply: _commitFreeRotate),
        const SizedBox(height: 10),
        _panelTitle('裁剪'),
        const Text('在画布上拖拽框选区域；常用比例：',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (label, ratio) in [('1:1', 1.0), ('4:3', 4 / 3), ('16:9', 16 / 9)])
              OutlinedButton(
                onPressed: () {
                  // 以画布中心按比例取最大框
                  final size = _cropKey.currentContext?.size;
                  if (size == null) return;
                  final w = math.min(size.width, size.height * ratio);
                  final h = w / ratio;
                  final cx = size.width / 2, cy = size.height / 2;
                  _dragStart = Offset(cx - w / 2, cy - h / 2);
                  _dragNow = Offset(cx + w / 2, cy + h / 2);
                  _onDragEnd(size, (w: src.width, h: src.height));
                },
                child: Text(label),
              ),
          ],
        ),
      ],
    );
  }

  Widget _slider(String label, double value, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            Text('${(value * 100).round()}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
        ),
        Slider(
          value: value,
          min: -1,
          max: 1,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _adjustProps() {
    double b = 0, c = 0, s = 0, t = 0, v = 0;
    return StatefulBuilder(
      builder: (context, setD) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelTitle('调整'),
          _slider('亮度', b, (x) => setD(() => b = x)),
          _slider('对比度', c, (x) => setD(() => c = x)),
          _slider('饱和度', s, (x) => setD(() => s = x)),
          _slider('色温', t, (x) => setD(() => t = x)),
          _slider('暗角', v, (x) => setD(() => v = x)),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () {
              final params = <String, double>{};
              if (b != 0) params['brightness'] = b;
              if (c != 0) params['contrast'] = c;
              if (s != 0) params['saturation'] = s;
              if (t != 0) params['temperature'] = t;
              if (v != 0) params['vignette'] = v;
              _commitAdjust(params);
            },
            child: const Text('应用调整'),
          ),
        ],
      ),
    );
  }

  Widget _presetProps() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelTitle('滤镜预设'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (name, label) in [
              ('bw', '黑白'),
              ('sepia', '复古'),
              ('film', '胶片'),
              ('cool', '冷调'),
              ('warm', '暖调'),
              ('fade', '褪色'),
            ])
              OutlinedButton(
                onPressed: () => _commitPreset(name),
                child: Text(label),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const Text('预设等价于一组调整参数，可在「调整」中继续微调。',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _annotateProps() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelTitle('标注'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (kind, label) in [
              (AnnotateKinds.rect, '矩形'),
              (AnnotateKinds.ellipse, '椭圆'),
              (AnnotateKinds.arrow, '箭头'),
              (AnnotateKinds.text, '文字'),
              (AnnotateKinds.mosaic, '马赛克'),
              (AnnotateKinds.doodle, '涂鸦'),
            ])
              ChoiceChip(
                label: Text(label),
                selected: _annotateKind == kind,
                onSelected: (_) => setState(() => _annotateKind = kind),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const Text('在画布上拖拽绘制；「文字」点击落点后输入内容。',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _resizeProps() {
    final ctrl = TextEditingController(
        text: _controller!.source.width.toString());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelTitle('尺寸'),
        TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: '目标宽度（px，等比缩放）'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () {
            final w = int.tryParse(ctrl.text);
            if (w != null && w > 0) _commitResize(w, null);
          },
          child: const Text('应用缩放（双线性）'),
        ),
      ],
    );
  }
}

/// 对比按钮：按住显示原图，松开恢复预览（4.3.3「与原图对比」）。
class _CompareButton extends StatefulWidget {
  const _CompareButton({required this.source});

  final ui.Image source;

  @override
  State<_CompareButton> createState() => _CompareButtonState();
}

class _CompareButtonState extends State<_CompareButton> {
  bool _showSource = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => setState(() => _showSource = true),
      onLongPressEnd: (_) => setState(() => _showSource = false),
      child: IconButton(
        onPressed: null,
        icon: Icon(
          Icons.compare,
          size: 20,
          color: _showSource ? AppColors.accent : null,
        ),
        tooltip: '按住与原图对比',
      ),
    );
  }
}

/// 自由旋转控制：滑杆 -180°~180°，实时显示角度，应用入栈。
class _FreeRotateControl extends StatefulWidget {
  const _FreeRotateControl({required this.onApply});

  final ValueChanged<double> onApply;

  @override
  State<_FreeRotateControl> createState() => _FreeRotateControlState();
}

class _FreeRotateControlState extends State<_FreeRotateControl> {
  double _deg = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _deg,
                min: -180,
                max: 180,
                divisions: 72, // 5° 步进
                label: '${_deg.round()}°',
                onChanged: (v) => setState(() => _deg = v),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text('${_deg.round()}°',
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _deg == 0 ? null : () {
              widget.onApply(_deg);
              setState(() => _deg = 0);
            },
            child: const Text('应用旋转'),
          ),
        ),
      ],
    );
  }
}

