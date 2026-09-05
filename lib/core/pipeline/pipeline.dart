/// 管道：有序 FilterNode 序列 + 历史栈（撤销/重做/跳转）。
///
/// 管道定义可持久化为 JSON 数组（设计书 3.4 节操作栈格式）。
/// 求值由 UI/导出层注入，core 层不接触像素。
library;

import 'node.dart';

/// 管道求值回调：输入节点序列，产出渲染结果（由 UI 层实现）。
typedef PipelineEvaluator<R> = R Function(List<FilterNode> nodes);

class ImagePipeline {
  ImagePipeline({List<FilterNode>? nodes}) : _nodes = List.of(nodes ?? const []);

  List<FilterNode> _nodes;

  /// 历史：已撤销节点栈。
  final List<List<FilterNode>> _undoStack = [];
  final List<List<FilterNode>> _redoStack = [];

  /// 只读当前节点序列。
  List<FilterNode> get nodes => List.unmodifiable(_nodes);
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  bool get isEmpty => _nodes.isEmpty;

  /// 追加节点（编辑操作入栈）。
  void add(FilterNode node) {
    _pushUndo();
    _nodes.add(node);
  }

  /// 在指定位置插入（指令式处理常用）。
  void insert(int index, FilterNode node) {
    if (index < 0 || index > _nodes.length) {
      throw RangeError.range(index, 0, _nodes.length);
    }
    _pushUndo();
    _nodes.insert(index, node);
  }

  /// 移除末尾/指定位置的节点。
  FilterNode removeAt(int index) {
    if (index < 0 || index >= _nodes.length) {
      throw RangeError.range(index, 0, _nodes.length - 1);
    }
    _pushUndo();
    return _nodes.removeAt(index);
  }

  /// 重置为全新节点序列（一键「回到原图」）。
  void reset(List<FilterNode>? nodes) {
    _pushUndo();
    _nodes = List.of(nodes ?? const []);
  }

  bool undo() {
    if (_undoStack.isEmpty) return false;
    _redoStack.add(List.of(_nodes));
    _nodes = _undoStack.removeLast();
    return true;
  }

  bool redo() {
    if (_redoStack.isEmpty) return false;
    _undoStack.add(List.of(_nodes));
    _nodes = _redoStack.removeLast();
    return true;
  }

  /// 序列化为编辑操作栈 JSON（3.4 节格式）。
  List<Map<String, Object?>> toJson() =>
      [for (final n in _nodes) n.toJson()];

  /// 从 JSON 数组恢复（坏数据整体拒绝，保证编辑栈完整）。
  static ImagePipeline fromJson(List<dynamic>? json) {
    if (json == null) return ImagePipeline();
    return ImagePipeline(
      nodes: [for (final e in json) FilterNode.fromJson((e as Map).cast<String, Object?>())],
    );
  }

  void _pushUndo() {
    _undoStack.add(List.of(_nodes));
    _redoStack.clear();
  }
}
