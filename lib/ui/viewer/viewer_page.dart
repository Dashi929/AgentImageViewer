/// 浏览视图（设计书 4.3.2）：全窗沉浸式，悬浮控件 2 秒自动淡出。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_state.dart';
import '../../core/image/exif.dart';
import '../../core/image/image_manager.dart';
import '../../core/scanner.dart';
import '../../core/viewer/slideshow.dart';
import '../../core/viewer/viewer_state.dart';
import '../../platform/trash.dart';
import '../shortcuts_sheet.dart';
import '../theme.dart';

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.list, required this.initialIndex});

  final List<ImageEntry> list;
  final int initialIndex;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> with WidgetsBindingObserver {
  late final ViewerNavigator _nav =
      ViewerNavigator(count: widget.list.length, initial: widget.initialIndex);
  final ViewerState _view = ViewerState();

  ui.Image? _displayImage; // 当前呈现（先降采样后全量替换）
  String? _pinnedKey; // 当前显示条目的缓存引用
  int _displayRotateTurns = 0;
  ExifData? _exif;
  bool _infoOpen = false;
  bool _fullscreen = false;

  bool _controlsVisible = true;
  Timer? _hideTimer;

  // 动图播放（GIF/WebP）：自动播放，空格暂停取帧（设计书 2.2）
  ui.Codec? _animCodec;
  Timer? _animTimer;
  bool _animPaused = false;

  // 幻灯片（设计书 2.2：间隔 1/3/5/10s 可选，随机与循环）
  bool _slideshow = false;
  int _slideIntervalSec = 3;
  bool _slideRandom = false;
  bool _slideLoop = true;
  Timer? _slideTimer;
  final math.Random _slideRng = math.Random();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openCurrent());
    _armHideTimer();
  }

  // 移动端生命周期：退后台立即停止动图取帧（设计书 3.3）
  bool _wasAnimPaused = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _wasAnimPaused = _animPaused;
        if (_animCodec != null && !_animPaused) {
          _animPaused = true;
          _animTimer?.cancel();
        }
      case AppLifecycleState.resumed:
        if (_animCodec != null && _animPaused && !_wasAnimPaused) {
          _animPaused = false;
          _playNextFrame();
        }
      default:
        break;
    }
  }

  ImageEntry get _entry => widget.list[_nav.index];
  AppState get _app => AppStateScope.of(context);

  Future<void> _openCurrent() async {
    final e = _entry;
    _displayImage = null;
    _displayRotateTurns = 0;
    _exif = null;
    setState(() {});

    // 两段式：先屏幕尺寸解码立即呈现，未命中时再换入全量（设计书 2.2）
    final vp = _view.viewportW > 0 ? _view.viewportW : 1200;
    final dpr = View.of(context).devicePixelRatio;
    final previewTarget = (vp * dpr).clamp(320, 2048).toInt();
    final preview = await _app.images
        .decode(e.path, e.mtimeMs, target: previewTarget, autoPin: true);
    if (_entry.path != e.path) return;
    _applyDecoded(preview);
    _view.resetForImage(preview.width, preview.height, _view.viewportW, _view.viewportH);
    setState(() {});

    // 大图分级解码（设计书 3.3）：fit 级立即呈现，放大时按需升级，
    // 避免 1 亿像素级原图整图解码的内存峰值。
    if (_entry.path == e.path) {
      _view.resetForImage(preview.width, preview.height, _view.viewportW, _view.viewportH);
      setState(() {});
      unawaited(_maybeAnimate(e));
      _prefetchNeighbors();
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStripVisible());
      unawaited(_maybeUpgrade());
    }
  }

  /// 分级升级：缩放使所需分辨率超当前显示 1.5 倍时，解码更高级位图替换。
  /// 上限 4096（≈43MB 位图内存），兼顾清晰度与内存上限（设计书 3.3）。
  Future<void> _maybeUpgrade() async {
    if (_upgrading || !mounted) return;
    final img = _displayImage;
    if (img == null || _view.imageWidth == 0) return;
    final dpr = View.of(context).devicePixelRatio;
    final fitTarget = (_view.viewportW * dpr).clamp(320, 2048).toInt();
    final upper = math.min(_view.imageWidth, 4096);
    final desired =
        (_view.imageWidth * _view.scale * dpr).round().clamp(fitTarget, upper).toInt();
    if (desired <= img.width * 3 ~/ 2) return; // 提升不足 50% 不值得重解码
    _upgrading = true;
    try {
      final e = _entry;
      final d = await _app.images.decode(e.path, e.mtimeMs, target: desired);
      if (!mounted || _entry.path != e.path) return;
      _applyDecoded(d);
      setState(() {});
    } catch (_) {
      // 升级失败保持当前级
    } finally {
      _upgrading = false;
    }
  }

  Future<void> _maybeAnimate(ImageEntry e) async {
    _animTimer?.cancel();
    _animCodec = null;
    _animPaused = false;
    try {
      final bytes = await File(e.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      if (codec.frameCount <= 1 || _entry.path != e.path) {
        codec.dispose();
        return;
      }
      _animCodec = codec;
      _playNextFrame();
    } catch (_) {
      // 解码失败保持静态呈现
    }
  }

  Future<void> _playNextFrame() async {
    final codec = _animCodec;
    if (codec == null || _animPaused || !mounted) return;
    final info = await codec.getNextFrame();
    if (!mounted || _animCodec != codec) {
      info.image.dispose();
      return;
    }
    // 动图帧由本页自管（离开即释放），不走 ImageManager 缓存
    if (_pinnedKey != null) _app.images.unpin(_pinnedKey!);
    _pinnedKey = null;
    _displayImage = info.image;
    setState(() {});
    _animTimer = Timer(info.duration, () => _playNextFrame());
  }

  TextEditingController? _renameCtrl;

  /// F2 虚拟重命名当前图（设计书 5.3：虚拟操作，不修改真实文件）
  Future<void> _renameCurrent() async {
    final e = _entry;
    _renameCtrl = TextEditingController(text: e.virtualName ?? e.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('虚拟重命名（不修改真实文件）'),
        content: TextField(controller: _renameCtrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _renameCtrl?.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name == null) return;
    _app.library.setVirtualName(e.path, name.isEmpty ? null : name);
    await _app.library.flush();
    if (mounted) setState(() {});
  }

  Future<void> _deleteCurrent() async {
    final path = _entry.path;
    final ok = await moveToRecycleBin(path);
    if (!mounted) return;
    if (ok) {
      await _app.library.rescan();
      _showOsd('已移入回收站');
      // 从当前列表移除；若空则回图库
      widget.list.removeWhere((e) => e.path == path);
      if (widget.list.isEmpty) {
        NavigatorStateEx.closeViewer();
      } else if (_nav.index >= widget.list.length) {
        _nav.last();
        _openCurrent();
      }
    } else {
      _showOsd('移入回收站失败');
    }
  }

  // ---------- 幻灯片（设计书 2.2 / 表 5-3） ----------

  void _toggleSlideshow() {
    if (_slideshow) {
      _stopSlideshow();
    } else {
      _startSlideshow();
    }
  }

  void _startSlideshow() {
    _slideshow = true;
    _showOsd('幻灯片开始');
    _scheduleNextSlide();
    setState(() {});
  }

  void _stopSlideshow() {
    _slideshow = false;
    _slideTimer?.cancel();
    _slideTimer = null;
    _showOsd('幻灯片暂停');
    setState(() {});
  }

  void _scheduleNextSlide() {
    _slideTimer?.cancel();
    if (!_slideshow) return;
    _slideTimer = Timer(Duration(seconds: _slideIntervalSec), _advanceSlide);
  }

  void _advanceSlide() {
    if (!_slideshow || !mounted) return;
    final next = nextSlideIndex(
      current: _nav.index,
      count: _nav.count,
      random: _slideRandom,
      loop: _slideLoop,
      rng: _slideRng,
    );
    if (next == null) {
      _stopSlideshow();
      _showOsd('幻灯片播放完毕');
      return;
    }
    _nav.index = next;
    _openCurrent();
    _scheduleNextSlide();
  }

  /// 幻灯片设置弹层：间隔 1/3/5/10 秒、随机、循环。
  Future<void> _showSlideshowSettings() async {
    _wakeControls();
    await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(200, 400, 200, 200),
      items: [
        for (final sec in slideshowIntervals)
          PopupMenuItem(
            value: 'i$sec',
            child: Row(
              children: [
                if (sec == _slideIntervalSec)
                  const Icon(Icons.check, size: 16, color: AppColors.accent)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 6),
                Text('$sec 秒间隔'),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'random',
          child: Row(
            children: [
              Icon(
                _slideRandom ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
                color: _slideRandom ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              const Text('随机顺序'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'loop',
          child: Row(
            children: [
              Icon(
                _slideLoop ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
                color: _slideLoop ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              const Text('循环播放'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      setState(() {
        if (value.startsWith('i')) {
          _slideIntervalSec = int.parse(value.substring(1));
        } else if (value == 'random') {
          _slideRandom = !_slideRandom;
        } else if (value == 'loop') {
          _slideLoop = !_slideLoop;
        }
      });
      if (_slideshow) _scheduleNextSlide(); // 间隔变更立即生效
    });
  }

  void _toggleAnimPause() {
    if (_animCodec == null) return;
    _animPaused = !_animPaused;
    if (!_animPaused) _playNextFrame();
    _showOsd(_animPaused ? '已暂停' : '播放中');
  }

  void _applyDecoded(DecodedImage d) {
    if (_pinnedKey != null) _app.images.unpin(_pinnedKey!);
    _pinnedKey = d.cacheKey;
    _displayImage = d.image;
    final e = _entry;
    if (e.width != d.width || e.height != d.height) {
      e.width = d.width;
      e.height = d.height;
    }
  }

  // 手势滑动累计（适应态翻页/返回判定）
  Offset _swipeAccum = Offset.zero;
  bool _upgrading = false; // 分级解码进行中
  final ScrollController _stripController = ScrollController();

  /// 打开新图后把缩略图条滚动到当前项可见。
  void _ensureStripVisible() {
    if (!_stripController.hasClients) return;
    const itemW = 82.0; // 76 + 6 间距
    final target = _nav.index * itemW;
    final vp = _stripController.position.viewportDimension;
    final cur = _stripController.offset;
    if (target < cur || target + itemW > cur + vp) {
      _stripController.animateTo(
        (target - vp / 2 + itemW / 2)
            .clamp(0.0, _stripController.position.maxScrollExtent),
        duration: AppTheme.motionDuration,
        curve: AppTheme.curve,
      );
    }
  }

  void _navigate(bool forward) {
    final moved = forward ? _nav.next() : _nav.previous();
    if (moved) _openCurrent();
  }

  Future<void> _safePrefetch(String path, int mtimeMs, int target) async {
    try {
      await _app.images.decode(path, mtimeMs, target: target);
    } catch (_) {/* 预解码失败不影响浏览 */}
  }

  /// 预解码前后各 5 张（target=屏幕尺寸级），翻页命中缓存即秒切。
  void _prefetchNeighbors() {
    const radius = 5;
    final vp = (_view.viewportW > 0 ? _view.viewportW : 1200).round();
    final target = (vp * View.of(context).devicePixelRatio).clamp(320, 2048).toInt();
    for (var d = 1; d <= radius; d++) {
      for (final i in [_nav.index - d, _nav.index + d]) {
        if (i < 0 || i >= widget.list.length) continue;
        final e = widget.list[i];
        if (e.path == _entry.path) continue;
        unawaited(_safePrefetch(e.path, e.mtimeMs, target));
      }
    }
  }

  void _toggleFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) return;
    _fullscreen = !_fullscreen;
    await windowManager.setFullScreen(_fullscreen);
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  DateTime? _lastTapAt;
  Offset? _lastTapPos;

  /// 自实现双击：适应窗口 ↔ 100% 实际像素（设计书 表 5-1）。
  /// 不用 GestureDetector.onDoubleTap——它会与 scale 手势产生 arena 竞争而失效。
  void _handleTapUp(PointerUpEvent e) {
    final now = DateTime.now();
    final pos = e.localPosition;
    final isDouble = _lastTapAt != null &&
        now.difference(_lastTapAt!) < const Duration(milliseconds: 320) &&
        _lastTapPos != null &&
        (pos - _lastTapPos!).distance < 48;
    _lastTapAt = isDouble ? null : now;
    _lastTapPos = pos;
    if (!isDouble) return;
    if (_view.isAtFit) {
      _view.actualSize();
      _showOsd('100%');
    } else {
      _view.fitWindow();
      _showOsd('适应窗口');
    }
    setState(() {});
  }

  void _wakeControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _armHideTimer();
  }

  void _showOsd(String text) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 800),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.overlay,
        content: Center(child: Text(text, style: const TextStyle(fontSize: 13))),
      ));
  }

  Future<void> _toggleInfo() async {
    setState(() => _infoOpen = !_infoOpen);
    if (_infoOpen && _exif == null) {
      final bytes = await File(_entry.path).readAsBytes();
      final data = parseExif(Uint8List.fromList(bytes));
      if (mounted) setState(() => _exif = data);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _slideTimer?.cancel();
    _animTimer?.cancel();
    _animCodec?.dispose();
    _displayImage?.dispose(); // 动图帧自管，静态图由 ImageManager 统一释放
    final key = _pinnedKey;
    if (key != null) _app.images.unpin(key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _navigate(false),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _navigate(true),
        const SingleActivator(LogicalKeyboardKey.home): () {
          _nav.first();
          _openCurrent();
        },
        const SingleActivator(LogicalKeyboardKey.end): () {
          _nav.last();
          _openCurrent();
        },
        const SingleActivator(LogicalKeyboardKey.equal): () => _zoom(1.25),
        const SingleActivator(LogicalKeyboardKey.minus): () => _zoom(0.8),
        const SingleActivator(LogicalKeyboardKey.digit0): () {
          _view.fitWindow();
          setState(() {});
          _showOsd('适应窗口');
        },
        const SingleActivator(LogicalKeyboardKey.digit1): () {
          _view.actualSize();
          setState(() {});
          _showOsd('100%');
        },
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_fullscreen) {
            _toggleFullscreen();
          } else {
            NavigatorStateEx.closeViewer();
          }
        },
        const SingleActivator(LogicalKeyboardKey.space): () {
          if (_animCodec != null) {
            _toggleAnimPause();
          } else {
            _toggleSlideshow();
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyI): _toggleInfo,
        const SingleActivator(LogicalKeyboardKey.slash, shift: true):
            () => showShortcutSheet(context),
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
            NavigatorStateEx.editor.value = _entry,
        const SingleActivator(LogicalKeyboardKey.delete): _deleteCurrent,
        const SingleActivator(LogicalKeyboardKey.f2): _renameCurrent,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: AppColors.mainBg,
          body: LayoutBuilder(
            builder: (context, c) {
              _view.setViewport(
                  c.maxWidth - (_infoOpen ? 280 : 0), c.maxHeight);
              return MouseRegion(
                onHover: (_) => _wakeControls(),
                child: Row(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          _canvas(),
                          ..._overlays(),
                          _thumbStrip(),
                        ],
                      ),
                    ),
                    if (_infoOpen) _infoPanel(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // ---------- 画布 ----------

  Widget _canvas() {
    final img = _displayImage;
    if (img == null) {
      return const Center(
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent));
    }
    return Listener(
      behavior: HitTestBehavior.opaque, // 画布整面可命中（含图像外黑边）
      onPointerDown: (d) {
        // 鼠标侧键（设计书 表 5-1：前进/后退 → 下一张/上一张）
        if (d.buttons == 8) _navigate(false); // 后退侧键
        if (d.buttons == 16) _navigate(true); // 前进侧键
        _wakeControls(); // 触屏：触摸即唤醒控件（设计书 4.2）
      },
      onPointerMove: (_) => _wakeControls(),
      onPointerUp: _handleTapUp,
      onPointerSignal: (s) {
        if (s is PointerScrollEvent) {
          final factor = math.exp(-s.scrollDelta.dy * 0.0015);
          _zoomAt(factor, s.localPosition);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque, // 整面手势区（翻页/上滑返回不限于图像像素）
        // 统一缩放手势：双指捏合以双指中心为锚点；单指拖拽平移（设计书 表 5-2）
        onScaleStart: (d) => _swipeAccum = Offset.zero,
        onScaleUpdate: (d) {
          if (d.scale != 1.0) {
            _view.zoomAt(d.scale, d.localFocalPoint.dx, d.localFocalPoint.dy);
          } else {
            _view.pan(d.focalPointDelta.dx, d.focalPointDelta.dy);
          }
          _swipeAccum += d.focalPointDelta;
          setState(() {});
        },

        onScaleEnd: (d) {
          // 适应态：左右滑动翻页（跟手位移由 pan 已呈现，此处按速度翻页）
          if (_view.isAtFit) {
            if (d.velocity.pixelsPerSecond.dx < -600 &&
                _swipeAccum.dx < -60) {
              _navigate(true);
            } else if (d.velocity.pixelsPerSecond.dx > 600 &&
                _swipeAccum.dx > 60) {
              _navigate(false);
            } else if (d.velocity.pixelsPerSecond.dy < -800 &&
                _swipeAccum.dy < -80) {
              NavigatorStateEx.closeViewer(); // 底部上滑返回图库
            }
          }
          _swipeAccum = Offset.zero;
          setState(() {});
          unawaited(_maybeUpgrade());
        },
        child: _buildTransform(img),
      ),
    );
  }

  Widget _buildTransform(ui.Image img) {
    return ClipRect(
      child: Stack(
        children: [
          Positioned(
            left: _view.offsetX,
            top: _view.offsetY,
            child: Transform.rotate(
              angle: _displayRotateTurns * math.pi / 2,
              alignment: Alignment.center,
              child: SizedBox(
                width: _view.imageWidth * _view.scale,
                height: _view.imageHeight * _view.scale,
                child: RawImage(
                  image: img,
                  fit: BoxFit.fill,
                  width: _view.imageWidth.toDouble(),
                  height: _view.imageHeight.toDouble(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _zoom(double factor) {
    _view.zoomAt(factor, _view.viewportW / 2, _view.viewportH / 2);
    setState(() {});
    _showOsd('${(_view.scale * 100).round()}%');
    unawaited(_maybeUpgrade());
  }

  void _zoomAt(double factor, Offset focal) {
    _view.zoomAt(factor, focal.dx, focal.dy);
    setState(() {});
  }

  // ---------- 悬浮控件 ----------

  List<Widget> _overlays() => [
        AnimatedOpacity(
          opacity: _controlsVisible ? 1 : 0,
          duration: AppTheme.motionDuration,
          curve: AppTheme.curve,
          child: IgnorePointer(
            ignoring: !_controlsVisible,
            child: Column(
              children: [
                _topBar(),
                const Spacer(),
                _bottomBar(),
              ],
            ),
          ),
        ),
      ];

  Widget _topBar() {
    return Container(
      height: 48,
      color: AppColors.overlay.withValues(alpha: 0.92),
      child: Row(
        children: [
          IconButton(
            onPressed: NavigatorStateEx.closeViewer,
            icon: const Icon(Icons.arrow_back, size: 20),
            tooltip: '返回图库 (Esc)',
          ),
          Expanded(
            child: Text(
              '${_entry.name}  ·  ${_entry.width ?? '?'}×${_entry.height ?? '?'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
            ),
          ),
          const SizedBox(width: 100, height: 36),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final idx = _nav.index + 1;
    return Container(
      height: 52,
      margin: const EdgeInsets.only(left: 24, right: 24, bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.overlay.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _barBtn(Icons.zoom_out, '缩小 (-)', () => _zoom(0.8)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('${(_view.scale * 100).round()}%',
                style: const TextStyle(fontSize: 12, color: AppColors.textPrimary)),
          ),
          _barBtn(Icons.zoom_in, '放大 (+)', () => _zoom(1.25)),
          _barBtn(Icons.fit_screen, '适应窗口 (0)', () {
            _view.fitWindow();
            setState(() {});
          }),
          _barBtn(Icons.crop_free, '实际大小 (1)', () {
            _view.actualSize();
            setState(() {});
          }),
          const VerticalDivider(width: 12, indent: 12, endIndent: 12),
          _barBtn(
            _slideshow ? Icons.pause_circle_outline : Icons.slideshow,
            _slideshow ? '暂停幻灯片 (Space)' : '幻灯片 (Space)',
            _toggleSlideshow,
          ),
          _barBtn(Icons.tune, '幻灯片设置', _showSlideshowSettings),
          _barBtn(Icons.edit_outlined, '编辑 (Ctrl+E)', () {
            NavigatorStateEx.editor.value = _entry;
          }),
          _barBtn(Icons.info_outline, '信息 (I)', _toggleInfo),
          const VerticalDivider(width: 12, indent: 12, endIndent: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('$idx / ${_nav.count}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ),
        ],
      ),
      ),
    );
  }

  Widget _barBtn(IconData icon, String tip, VoidCallback onTap) {
    return IconButton(
      onPressed: () {
        _wakeControls();
        onTap();
      },
      icon: Icon(icon, size: 20, color: AppColors.textPrimary),
      tooltip: tip,
    );
  }

  // ---------- 缩略图预览条 ----------

  Widget _thumbStrip() {
    if (widget.list.length <= 1) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 84,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: AppTheme.motionDuration,
        curve: AppTheme.curve,
        child: IgnorePointer(
          ignoring: !_controlsVisible,
          child: SizedBox(
            height: 76,
            child: ListView.builder(
              controller: _stripController,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: widget.list.length,
              itemBuilder: (context, i) {
                final e = widget.list[i];
                final selected = i == _nav.index;
                return GestureDetector(
                  onTap: () {
                    _nav.index = i;
                    _openCurrent();
                  },
                  child: Container(
                    width: 76,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: selected ? AppColors.accent : Colors.white24,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: _StripThumb(entry: e),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 信息面板 ----------

  Widget _infoPanel() {
    final e = _entry;
    String sizeText = '-';
    final bytes = e.sizeBytes;
    sizeText = bytes > 1 << 20
        ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB'
        : '${(bytes / 1024).toStringAsFixed(0)} KB';

    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 64,
                  child: Text(k,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary))),
              Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textPrimary)),
              ),
            ],
          ),
        );

    return Container(
      width: 280,
      color: AppColors.panel,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                  child: Text('信息',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
              IconButton(
                onPressed: _toggleInfo,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          const Divider(),
          row('文件名', e.name),
          row('尺寸', '${e.width ?? '?'} × ${e.height ?? '?'}'),
          row('大小', sizeText),
          if (_exif != null) ...[
            const Divider(),
            if (_exif!.make != null || _exif!.model != null)
              row('相机', '${_exif!.make ?? ''} ${_exif!.model ?? ''}'.trim()),
            if (_exif!.dateTimeOriginal != null) row('拍摄时间', _exif!.dateTimeOriginal!),
            if (_exif!.fNumber != null) row('光圈', _exif!.apertureDisplay),
            if (_exif!.exposureTimeSeconds != null) row('快门', _exif!.exposureDisplay),
            if (_exif!.iso != null) row('ISO', '${_exif!.iso}'),
            if (_exif!.focalLengthMm != null) row('焦距', '${_exif!.focalLengthMm!.round()}mm'),
          ],
        ],
      ),
    );
  }
}

/// 缩略图条单元：160px 磁盘缓存缩略图。
class _StripThumb extends StatefulWidget {
  const _StripThumb({required this.entry});

  final ImageEntry entry;

  @override
  State<_StripThumb> createState() => _StripThumbState();
}

class _StripThumbState extends State<_StripThumb> {
  ImageManager? _mgr;
  String? _pinnedKey;
  ui.Image? _image;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  Future<void> _load() async {
    final app = AppStateScope.of(context, listen: false);
    _mgr = app.images;
    try {
      final d = await app.images.decode(
          widget.entry.path, widget.entry.mtimeMs,
          target: 160, autoPin: true);
      if (mounted) {
        _pinnedKey = d.cacheKey;
        setState(() => _image = d.image);
      }
    } catch (_) {/* 坏图保持空态 */}
  }

  @override
  void dispose() {
    final k = _pinnedKey;
    if (k != null) _mgr?.unpin(k);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) {
      return const ColoredBox(color: Color(0xFF23272F));
    }
    return RawImage(
        image: img, fit: BoxFit.contain, width: double.infinity, height: double.infinity);
  }
}
