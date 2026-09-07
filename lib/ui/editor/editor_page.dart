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

  // 快捷键（Ctrl+Z/Y/S、Esc）依赖焦点在本页子树内；根壳的 autofocus
  // 会抢在页面 autofocus 之前持有焦点，必须在就绪后显式 requestFocus。
  final FocusNode _focusNode = FocusNode(debugLabel: 'editor');

  // 裁剪/标注的拖拽状态（画布坐标，导出时换算相对比例）
  Offset? _dragStart;
  Offset? _dragNow;
  Offset? _panDownPos; // onDown 记录的真实按下位置（画布坐标）
  final List<Offset> _doodlePts = [];

  // 裁剪会话（PS 式两阶段：先出选区预览，确认才入栈生效）
  Rect? _cropSession; // 选区（相对比例，基于当前输出画幅）
  bool _cropSelecting = false; // 已进入自由裁剪（画布拖拽更新选区）

  // 调整滑杆的会话状态（须放在 State 上：拖动中控制器 notify 会整页重建；
  // 滑杆常态显示已提交的合并值，拖动会话内显示会话绝对值）
  static const _adjustKeys = [
    ('brightness', '亮度'),
    ('contrast', '对比度'),
    ('saturation', '饱和度'),
    ('temperature', '色温'),
    ('vignette', '暗角'),
  ];
  final Map<String, double> _adjustDrag = {};
  Map<String, double>? _adjustBaseline; // 会话开始时已提交的合并值

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
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

  void _addFlip(String axis) => _addNode(FilterNode(op: Ops.flip, params: {'axis': axis}));

  // ---------- 裁剪会话（预览 → 确认生效） ----------

  /// 有效节点 = 已提交节点 + 自由旋转预览（滑杆拖动中即时呈现）。
  List<FilterNode> _effectiveNodes(EditorController ctrl) {
    final deg = ctrl.freeRotatePreview;
    return deg == null
        ? ctrl.pipeline.nodes
        : [
            ...ctrl.pipeline.nodes,
            FilterNode(op: Ops.freeRotate, params: {'deg': deg}),
          ];
  }

  /// 已提交的累计自由旋转角（栈尾为 free_rotate 时取其角度）。
  double _committedFreeRotateDeg(EditorController ctrl) {
    final nodes = ctrl.pipeline.nodes;
    if (nodes.isEmpty || nodes.last.op != Ops.freeRotate) return 0;
    return (nodes.last.params['deg'] as num).toDouble();
  }

  void _startFreeCrop() {
    setState(() {
      _cropSelecting = true;
      _cropSession = null;
      _dragStart = null;
      _dragNow = null;
    });
  }

  /// 预设比例：以当前输出画幅中心取该比例的最大选区（进入预览，待确认）。
  void _applyCropRatio(double ratio) {
    final ctrl = _controller;
    if (ctrl == null) return;
    final out = sizeAfter(_effectiveNodes(ctrl), ctrl.source.width, ctrl.source.height);
    final a = out.w / out.h;
    double rw, rh;
    if (a / ratio >= 1) {
      rh = 1;
      rw = ratio / a;
    } else {
      rw = 1;
      rh = a / ratio;
    }
    setState(() {
      _cropSelecting = true;
      _dragStart = null;
      _dragNow = null;
      _cropSession = Rect.fromLTWH((1 - rw) / 2, (1 - rh) / 2, rw, rh);
    });
  }

  void _confirmCropSession() {
    final r = _cropSession;
    if (r == null || r.width < 0.02 || r.height < 0.02) return;
    _addNode(FilterNode(op: Ops.crop, params: {
      'x': r.left,
      'y': r.top,
      'w': r.width,
      'h': r.height,
    }));
    _clearCropSession();
  }

  void _clearCropSession() {
    setState(() {
      _cropSession = null;
      _cropSelecting = false;
      _dragStart = null;
      _dragNow = null;
    });
  }

  void _onConfirmKey() {
    if (_cropSession != null) _confirmCropSession();
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
    if (_tool == _Tool.crop) {
      // 仅自由裁剪模式下拖拽更新选区；选区不直接生效，待确认
      if (_cropSelecting) {
        _dragStart = local;
        _dragNow = local;
      }
    } else if (_tool == _Tool.annotate) {
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
      // 自由裁剪：拖拽结果进入选区预览，确认后才入栈
      final left = math.min(rx(s.dx), rx(e.dx));
      final right = math.max(rx(s.dx), rx(e.dx));
      final top = math.min(ry(s.dy), ry(e.dy));
      final bottom = math.max(ry(s.dy), ry(e.dy));
      if (right - left > 0.02 && bottom - top > 0.02) {
        _cropSession = Rect.fromLTRB(left, top, right, bottom);
      }
    } else if (_tool == _Tool.annotate) {
      switch (_annotateKind) {
        case AnnotateKinds.text:
          // 拖出的虚线框 = 文字框：锚点取框左上角，字号由框高换算
          final ctrl = _controller;
          if (ctrl != null) {
            final box = Rect.fromPoints(s, e);
            final out = sizeAfter(
                _effectiveNodes(ctrl), ctrl.source.width, ctrl.source.height);
            final fit = canvasSize.width / out.w;
            final fontSize = (box.height / fit).round().clamp(8, 400);
            _promptText().then((text) {
              if (text != null && text.isNotEmpty) {
                _addNode(FilterNode(op: Ops.annotate, params: {
                  'kind': AnnotateKinds.text,
                  'text': text,
                  'x': box.left.clamp(0, 1),
                  'y': box.top.clamp(0, 1),
                  'size': fontSize,
                }));
              }
              setState(() {});
            });
          }
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
        const SingleActivator(LogicalKeyboardKey.escape): () {
          // 裁剪会话优先：先取消选区，再退出编辑
          if (_cropSession != null || _dragStart != null) {
            _clearCropSession();
            return;
          }
          NavigatorStateEx.editor.value = null;
        },
        const SingleActivator(LogicalKeyboardKey.enter): _onConfirmKey,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _onConfirmKey,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): ctrl.undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): ctrl.redo,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _export,
      },
      child: Focus(
        focusNode: _focusNode,
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
            onTap: () => setState(() {
              _tool = t;
              // 切换工具时丢弃未确认的裁剪选区
              _cropSession = null;
              _cropSelecting = false;
              _dragStart = null;
              _dragNow = null;
            }),
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
      final effective = _effectiveNodes(ctrl);
      final out = sizeAfter(effective, ctrl.source.width, ctrl.source.height);
      final fit = math.min(canvas.width / out.w, canvas.height / out.h);
      final drawW = out.w * fit;
      final drawH = out.h * fit;
      final topLeft = Offset((canvas.width - drawW) / 2, (canvas.height - drawH) / 2);

      // 求值前尺寸（拖拽覆盖层用原图坐标系）
      final imgSize = sizeAfter(const [], ctrl.source.width, ctrl.source.height);

      // 裁剪选区：拖拽中的实时矩形优先，否则显示待确认会话选区
      Rect? cropRel;
      if (_tool == _Tool.crop) {
        if (_dragStart != null && _dragNow != null) {
          final a = _dragStart!, b = _dragNow!;
          cropRel = Rect.fromLTRB(
            math.min(a.dx, b.dx), math.min(a.dy, b.dy),
            math.max(a.dx, b.dx), math.max(a.dy, b.dy),
          );
        } else {
          cropRel = _cropSession;
        }
      }

      return Listener(
        // onPointerDown 记录真实按下位置：onPanStart 在手势竞争裁决（越过
        // slop）时才触发，其 localPosition 是裁决时事件位置，快速拖动会
        // 导致起点沿拖动方向偏移（拖动位置 ≠ 最终生成位置）
        onPointerDown: (d) => _panDownPos = d.localPosition,
        child: GestureDetector(
          onTapDown: (_) {},
          onPanStart: (d) =>
              _onDragStart((_panDownPos ?? d.localPosition) - topLeft, canvas, imgSize),
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
                final merged = mergedAdjustOf(effective);
                final pv = ctrl.adjustPreview;
                if (pv != null) {
                  merged
                    ..removeWhere((k, _) => pv.containsKey(k))
                    ..addAll(pv);
                }
                final filter = adjustColorFilter(merged);
                final paintLayer = CustomPaint(
                  size: Size(drawW, drawH),
                  painter: EditorPreviewPainter(
                      source: ctrl.source,
                      nodes: effective,
                      generation: ctrl.generation),
                );
                if (filter == null) return paintLayer;
                return ColorFiltered(
                    colorFilter: filter, child: paintLayer);
              }),
            ),
            // 透明棋盘格底（4.3.3）：由画布背景承担
            if (_tool == _Tool.annotate && _dragStart != null && _dragNow != null)
              Positioned.fill(
                child: CustomPaint(
                  painter: _AnnotateDragPainter(
                    kind: _annotateKind,
                    a: _dragStart! + topLeft,
                    b: _dragNow! + topLeft,
                    doodle: [for (final p in _doodlePts) p + topLeft],
                  ),
                ),
              ),
            // 裁剪选区预览（PS 式：选区外压暗 + 三分线，确认才生效）
            if (cropRel != null && cropRel.width > 0 && cropRel.height > 0)
              Positioned.fill(
                child: CustomPaint(
                  painter: _CropSessionPainter(
                    sel: Rect.fromLTWH(
                        topLeft.dx + cropRel.left * drawW,
                        topLeft.dy + cropRel.top * drawH,
                        cropRel.width * drawW,
                        cropRel.height * drawH),
                  ),
                ),
              ),
          ],
        ),
        ),
      );
    });
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
        _FreeRotateControl(
          currentDeg: _committedFreeRotateDeg(_controller!),
          onPreview: (deg) =>
              _controller?.setFreeRotatePreview(deg == 0 ? null : deg),
          onCommit: (deg) => _controller?.commitFreeRotate(deg),
        ),
        const SizedBox(height: 10),
        _panelTitle('裁剪'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            FilledButton.tonal(
              onPressed: _startFreeCrop,
              child: const Text('自由裁剪'),
            ),
            for (final (label, ratio) in [
              ('1:1', 1.0),
              ('4:3', 4 / 3),
              ('16:9', 16 / 9),
            ])
              OutlinedButton(
                onPressed: () => _applyCropRatio(ratio),
                child: Text(label),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_cropSession != null) ...[
          Builder(builder: (context) {
            final ctrl = _controller!;
            final out = sizeAfter(
                _effectiveNodes(ctrl), ctrl.source.width, ctrl.source.height);
            final w = (_cropSession!.width * out.w).round();
            final h = (_cropSession!.height * out.h).round();
            return Text('选区 $w × $h px，确认后生效',
                style: const TextStyle(fontSize: 12));
          }),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              FilledButton(
                onPressed: _confirmCropSession,
                child: const Text('应用裁剪 (Enter)'),
              ),
              OutlinedButton(
                onPressed: _clearCropSession,
                child: const Text('取消 (Esc)'),
              ),
            ],
          ),
        ] else
          const Text('「自由裁剪」后在画布上拖出选区；比例按钮直接给出居中选区。',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _slider(String label, double value, ValueChanged<double> onChanged,
      {ValueChanged<double>? onChangeStart, ValueChanged<double>? onChangeEnd}) {
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
          onChangeStart: onChangeStart,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }

  Widget _adjustProps() {
    final ctrl = _controller!;
    // 滑杆常态显示已提交的合并值（不再归 0）；拖动会话内显示会话绝对值
    final committed = mergedAdjustOf(ctrl.pipeline.nodes);
    double valueOf(String key) =>
        (_adjustDrag[key] ?? (committed[key] ?? 0)).clamp(-1, 1).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelTitle('调整'),
        for (final (key, label) in _adjustKeys)
          _slider(label, valueOf(key), (v) {
            setState(() => _adjustDrag[key] = v);
            ctrl.setAdjustPreview({key: v});
          },
              onChangeStart: (v) {
                // 会话起点：快照已提交的合并值，松手提交差值
                _adjustBaseline ??= committed;
                setState(() => _adjustDrag[key] = v);
              },
              onChangeEnd: (v) {
                final baseline = _adjustBaseline?[key] ?? 0;
                final delta = v - baseline;
                _adjustDrag.remove(key);
                if (_adjustDrag.isEmpty) _adjustBaseline = null;
                ctrl.setAdjustPreview(null);
                if (delta.abs() > 0.001) {
                  _addNode(FilterNode(op: Ops.adjust, params: {key: delta}));
                }
              }),
        const SizedBox(height: 4),
        const Text('拖动即时预览，松手生效；滑杆显示当前效果值，可继续微调。',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
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
        const Text('拖拽即见即所得：箭头/线条按拖动轨迹预览；「文字」拖出虚线框后输入内容。',
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

/// 自由旋转控制：滑杆显示当前累计角度；拖动即时预览，松手提交相对增量
/// （与栈尾自由旋转节点合并，多次旋转不重复烘焙包围盒）。
class _FreeRotateControl extends StatefulWidget {
  const _FreeRotateControl({
    required this.currentDeg,
    required this.onPreview,
    required this.onCommit,
  });

  final double currentDeg; // 已提交的累计角度
  final ValueChanged<double?> onPreview; // 相对已提交状态的追加角度
  final ValueChanged<double> onCommit;

  @override
  State<_FreeRotateControl> createState() => _FreeRotateControlState();
}

class _FreeRotateControlState extends State<_FreeRotateControl> {
  bool _dragging = false;
  double _deg = 0; // 拖动会话内的绝对角度

  @override
  Widget build(BuildContext context) {
    final value = _dragging ? _deg : widget.currentDeg;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Slider(
                value: value.clamp(-180, 180).toDouble(),
                min: -180,
                max: 180,
                divisions: 72, // 5° 步进
                label: '${value.round()}°',
                onChangeStart: (v) {
                  _dragging = true;
                  _deg = v;
                },
                onChanged: (v) {
                  setState(() => _deg = v);
                  widget.onPreview(v - widget.currentDeg); // 拖动中即时预览
                },
                onChangeEnd: (v) {
                  widget.onCommit(v - widget.currentDeg); // 松手落栈（合并提交）
                  setState(() {
                    _dragging = false;
                    _deg = 0;
                  });
                },
              ),
            ),
            SizedBox(
              width: 44,
              child: Text('${value.round()}°',
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }
}

/// 标注拖拽实时预览：视觉与已提交渲染（paintAnnotateVectors）一致——
/// 矩形/椭圆描边、箭头线+箭头头部、涂鸦折线、马赛克半透明块、文字虚线框。
class _AnnotateDragPainter extends CustomPainter {
  _AnnotateDragPainter({
    required this.kind,
    required this.a,
    required this.b,
    required this.doodle,
  });

  final String kind;
  final Offset a, b;
  final List<Offset> doodle;

  static const _accent = ui.Color(0xFFE5615C);

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    final stroke = ui.Paint()
      ..color = _accent
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2;
    switch (kind) {
      case AnnotateKinds.rect:
        canvas.drawRect(Rect.fromPoints(a, b), stroke);
      case AnnotateKinds.ellipse:
        canvas.drawOval(Rect.fromPoints(a, b), stroke);
      case AnnotateKinds.arrow:
        _drawArrow(canvas, a, b, stroke);
      case AnnotateKinds.mosaic:
        canvas.drawRect(Rect.fromPoints(a, b),
            ui.Paint()..color = const ui.Color(0x66000000));
        _drawDashedRect(
            canvas,
            Rect.fromPoints(a, b),
            ui.Paint()
              ..style = ui.PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = const ui.Color(0x66FFFFFF));
      case AnnotateKinds.text:
        _drawDashedRect(canvas, Rect.fromPoints(a, b), stroke);
      case AnnotateKinds.doodle:
        if (doodle.length > 1) {
          final pen = ui.Paint()
            ..color = _accent
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeCap = ui.StrokeCap.round;
          for (var i = 1; i < doodle.length; i++) {
            canvas.drawLine(doodle[i - 1], doodle[i], pen);
          }
        }
    }
  }

  void _drawArrow(ui.Canvas canvas, ui.Offset from, ui.Offset to, ui.Paint paint) {
    canvas.drawLine(from, to, paint);
    final dir = to - from;
    final len = dir.distance;
    if (len <= 0) return;
    ui.Offset rot(ui.Offset v, double ang) => ui.Offset(
        v.dx * math.cos(ang) - v.dy * math.sin(ang),
        v.dx * math.sin(ang) + v.dy * math.cos(ang));
    final u = dir / len;
    canvas.drawLine(to, to - rot(u, math.pi / 6) * 14, paint);
    canvas.drawLine(to, to - rot(u, -math.pi / 6) * 14, paint);
  }

  void _drawDashedRect(ui.Canvas canvas, ui.Rect r, ui.Paint paint) {
    const dash = 5.0, gap = 4.0;
    void line(ui.Offset p1, ui.Offset p2) {
      final total = (p2 - p1).distance;
      if (total == 0) return;
      final u = (p2 - p1) / total;
      var d = 0.0;
      while (d < total) {
        final e = math.min(d + dash, total);
        canvas.drawLine(p1 + u * d, p1 + u * e, paint);
        d = e + gap;
      }
    }

    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(covariant _AnnotateDragPainter old) =>
      old.kind != kind || old.a != a || old.b != b || old.doodle.length != doodle.length;
}

/// 裁剪选区预览：选区外压暗 + 强调色边框 + 三分参考线（确认前不入栈）。
class _CropSessionPainter extends CustomPainter {
  _CropSessionPainter({required this.sel});

  final Rect sel;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    final full = ui.Offset.zero & size;
    final path = ui.Path()
      ..fillType = ui.PathFillType.evenOdd
      ..addRect(full)
      ..addRect(sel);
    canvas.drawPath(path, ui.Paint()..color = const ui.Color(0x8A000000));

    canvas.drawRect(
        sel,
        ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const ui.Color(0xFF8B7CF6));
    final third = sel.width / 3;
    final gridPaint = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = const ui.Color(0x40FFFFFF);
    for (var i = 1; i <= 2; i++) {
      canvas.drawLine(ui.Offset(sel.left + third * i, sel.top),
          ui.Offset(sel.left + third * i, sel.bottom), gridPaint);
      canvas.drawLine(ui.Offset(sel.left, sel.top + sel.height / 3 * i),
          ui.Offset(sel.right, sel.top + sel.height / 3 * i), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CropSessionPainter old) => old.sel != sel;
}

