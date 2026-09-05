/// Filter Pipeline 节点定义。
///
/// 所有像素变换（几何、调整、滤镜、标注、尺寸）统一表达为 [FilterNode]。
/// 节点参数可序列化为 JSON（与设计书 3.4 节编辑操作栈格式互认），
/// 坐标类参数一律使用 0~1 相对比例，导出时才映射到像素。
library;

/// 操作类型常量。新增节点必须登记到这里与 [defaultRegistry]。
abstract final class Ops {
  static const rotate = 'rotate';
  static const freeRotate = 'free_rotate';
  static const flip = 'flip';
  static const crop = 'crop';
  static const adjust = 'adjust';
  static const preset = 'preset';
  static const annotate = 'annotate';
  static const resize = 'resize';
  static const aiEdit = 'ai_edit';
}

/// 调整类参数（均为 -1~1 相对量，与设计书 3.4 示例一致）。
abstract final class AdjustKeys {
  static const brightness = 'brightness';
  static const contrast = 'contrast';
  static const saturation = 'saturation';
  static const temperature = 'temperature';
  static const sharpness = 'sharpness';
  static const vignette = 'vignette';
}

/// 标注类型。
abstract final class AnnotateKinds {
  static const text = 'text';
  static const arrow = 'arrow';
  static const rect = 'rect';
  static const ellipse = 'ellipse';
  static const mosaic = 'mosaic';
  static const doodle = 'doodle';
}

/// Filter 节点：一个有序参数化的像素变换。
class FilterNode {
  FilterNode({required this.op, Map<String, Object?>? params})
      : params = _frozen(params ?? const {});

  final String op;

  /// 节点参数。坐标类值必须落在 0~1（相对比例）。
  final Map<String, Object?> params;

  Map<String, Object?> toJson() => {'op': op, 'params': Map<String, Object?>.of(params)};

  static FilterNode fromJson(Map<String, Object?> json) {
    final op = json['op'] as String?;
    final reg = defaultRegistry[op];
    if (reg == null) {
      throw FormatException('未知操作类型: $op');
    }
    return reg((json['params'] as Map?)?.cast<String, Object?>());
  }

  @override
  String toString() => 'FilterNode($op, $params)';
}

Map<String, Object?> _frozen(Map<String, Object?> m) =>
    Map.unmodifiable(Map<String, Object?>.of(m));

/// 校验给定 op 的参数；不合法抛 [ArgumentError]。
typedef NodeValidator = void Function(Map<String, Object?> params);

/// 节点工厂注册表：op → 构造器。
final Map<String, FilterNode Function(Map<String, Object?>?)> defaultRegistry =
    _buildRegistry();

Map<String, FilterNode Function(Map<String, Object?>?)> _buildRegistry() {
  FilterNode Function(Map<String, Object?>?) make(String op, NodeValidator validate) =>
      (params) {
        final p = params ?? const {};
        validate(p);
        return FilterNode(op: op, params: p);
      };


  final r = <String, FilterNode Function(Map<String, Object?>?)>{};

  // rotate: deg ∈ {90,180,270,-90}
  r[Ops.rotate] = make(Ops.rotate, (p) {
    final deg = p['deg'];
    if (deg is! num || const {90, 180, 270, -90}.contains(deg.toInt()) == false) {
      throw ArgumentError.value(deg, 'deg', '必须为 90/180/270/-90');
    }
  });

  // free_rotate: deg ∈ [-180, 180]（任意角度，包围盒扩展）
  r[Ops.freeRotate] = make(Ops.freeRotate, (p) {
    final deg = p['deg'];
    if (deg is! num || deg.isNaN || deg < -180 || deg > 180) {
      throw ArgumentError.value(deg, 'deg', '必须为 -180~180 的数值');
    }
  });

  // flip: axis ∈ {h, v}
  r[Ops.flip] = make(Ops.flip, (p) {
    if (p['axis'] is! String || !{'h', 'v'}.contains(p['axis'])) {
      throw ArgumentError.value(p['axis'], 'axis', '必须为 h 或 v');
    }
  });

  // crop: 相对比例矩形 x/y/w/h ∈ 0~1
  r[Ops.crop] = make(Ops.crop, (p) {
    for (final k in const ['x', 'y', 'w', 'h']) {
      final v = p[k];
      if (v is! num || v < 0 || v > 1) {
        throw ArgumentError.value(v, k, '裁剪参数必须为 0~1 相对比例');
      }
    }
    if ((p['w'] as num) <= 0 || (p['h'] as num) <= 0) {
      throw ArgumentError('裁剪宽高必须大于 0');
    }
  });

  // adjust: 各调整量 -1~1
  r[Ops.adjust] = make(Ops.adjust, (p) {
    if (p.isEmpty) throw ArgumentError('adjust 至少需要一个调整量');
    const keys = {
      AdjustKeys.brightness, AdjustKeys.contrast, AdjustKeys.saturation,
      AdjustKeys.temperature, AdjustKeys.sharpness, AdjustKeys.vignette,
    };
    for (final e in p.entries) {
      if (!keys.contains(e.key)) {
        throw ArgumentError.value(e.key, 'key', '未知调整项');
      }
      final v = e.value;
      if (v is! num || v < -1 || v > 1) {
        throw ArgumentError.value(v, e.key, '调整量必须在 -1~1');
      }
    }
  });

  // preset: name 非空字符串（预设等价于一组 adjust 组合，展开在求值层）
  r[Ops.preset] = make(Ops.preset, (p) {
    if ((p['name'] as String?)?.isEmpty ?? true) {
      throw ArgumentError.value(p['name'], 'name', '滤镜预设名不能为空');
    }
  });

  // annotate: kind + 相对坐标；kind ∈ AnnotateKinds
  r[Ops.annotate] = make(Ops.annotate, (p) {
    final kind = p['kind'];
    if (kind is! String || !const {
      AnnotateKinds.text, AnnotateKinds.arrow, AnnotateKinds.rect,
      AnnotateKinds.ellipse, AnnotateKinds.mosaic, AnnotateKinds.doodle,
    }.contains(kind)) {
      throw ArgumentError.value(kind, 'kind', '未知标注类型');
    }
    for (final k in const ['x', 'y']) {
      final v = p[k];
      if (v is! num || v < 0 || v > 1) {
        throw ArgumentError.value(v, k, '标注坐标必须为 0~1 相对比例');
      }
    }
  });

  // resize: width/height 至少一项为正整数
  r[Ops.resize] = make(Ops.resize, (p) {
    final w = p['width'], h = p['height'];
    final ok = (w is num && w > 0) || (h is num && h > 0);
    if (!ok) throw ArgumentError('resize 需要 width 或 height 至少一项 > 0');
  });

  // ai_edit: 生成式节点，payload 由 Agent 生成，求值前需用户确认
  r[Ops.aiEdit] = make(Ops.aiEdit, (p) {
    if ((p['prompt'] as String?)?.isEmpty ?? true) {
      throw ArgumentError.value(p['prompt'], 'prompt', 'ai_edit 需要指令文本');
    }
  });

  return r;
}
