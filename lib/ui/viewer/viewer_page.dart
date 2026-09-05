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
import '../../core/image/image_manager.dart' show DecodedImage;
import '../../core/scanner.dart';
import '../../core/viewer/viewer_state.dart';
import '../theme.dart';

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.list, required this.initialIndex});

  final List<ImageEntry> list;
  final int initialIndex;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
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

  @override
  void initState() {
    super.initState();
    _openCurrent();
    _armHideTimer();
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
    final previewTarget = (vp * MediaQuery.devicePixelRatioOf(context))
        .clamp(320, 2048)
        .toInt();
    final preview = await _app.images.decode(e.path, e.mtimeMs, target: previewTarget);
    if (_entry.path != e.path) return;
    _applyDecoded(preview);
    _view.resetForImage(preview.width, preview.height, _view.viewportW, _view.viewportH);
    setState(() {});

    final full = await _app.images.decode(e.path, e.mtimeMs);
    if (_entry.path == e.path) {
      _applyDecoded(full);
      _view.resetForImage(full.width, full.height, _view.viewportW, _view.viewportH);
      setState(() {});
      unawaited(_maybeAnimate(e));
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

  void _toggleAnimPause() {
    if (_animCodec == null) return;
    _animPaused = !_animPaused;
    if (!_animPaused) _playNextFrame();
    _showOsd(_animPaused ? '已暂停' : '播放中');
  }

  void _applyDecoded(DecodedImage d) {
    _app.images.pin(d.cacheKey);
    if (_pinnedKey != null) _app.images.unpin(_pinnedKey!);
    _pinnedKey = d.cacheKey;
    _displayImage = d.image;
    final e = _entry;
    if (e.width != d.width || e.height != d.height) {
      e.width = d.width;
      e.height = d.height;
    }
  }

  void _navigate(bool forward) {
    final moved = forward ? _nav.next() : _nav.previous();
    if (moved) _openCurrent();
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
    _hideTimer?.cancel();
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
        const SingleActivator(LogicalKeyboardKey.space): _toggleAnimPause,
        const SingleActivator(LogicalKeyboardKey.keyI): _toggleInfo,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
            NavigatorStateEx.editor.value = _entry,
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
      onPointerSignal: (s) {
        if (s is PointerScrollEvent) {
          final factor = math.exp(-s.scrollDelta.dy * 0.0015);
          _zoomAt(factor, s.localPosition);
        }
      },
      child: GestureDetector(
        onDoubleTap: () {
          if (_view.isAtFit) {
            _view.actualSize();
            _showOsd('100%');
          } else {
            _view.fitWindow();
            _showOsd('适应窗口');
          }
          setState(() {});
        },
        onPanUpdate: (d) {
          _view.pan(d.delta.dx, d.delta.dy);
          setState(() {});
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
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
          _barBtn(Icons.rotate_right, '旋转', () {
            _displayRotateTurns = (_displayRotateTurns + 1) % 4;
            setState(() {});
          }),
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
