/// Agent 工具集（设计书 表 2-4）：注册、描述、模型决议到本地执行的映射。
///
/// 红线：写真实文件的操作（rename_batch）必须先入待确认列表，经用户确认后执行；
/// 标签/分类/虚拟重命名一律虚拟操作，只写本地库。
library;

import 'dart:io';

import '../db/library.dart';

/// 「这张图」类指令解析：用户提到当前图（这张/当前/正在看/此图/它）且未给路径时，
/// 注入当前浏览图片路径作为上下文。纯函数。
String? resolveTargetPath(String userText, String? currentImagePath) {
  if (currentImagePath == null || currentImagePath.isEmpty) return null;
  final t = userText.toLowerCase();
  const refs = ['这张', '当前图', '正在看', '此图', '这一张', '当前这张', '它'];
  final hasRef = refs.any(t.contains);
  final hasExplicitPath =
      t.contains('/') || t.contains(String.fromCharCode(92));
  if (hasRef && !hasExplicitPath) return currentImagePath;
  return null;
}

class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
    required this.needsConfirm,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;
  final bool needsConfirm; // 需要用户确认的写操作

  Map<String, Object?> toOpenAiJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// 一条待确认的写操作（确认卡片）。
class PendingAction {
  PendingAction({required this.toolName, required this.summary, required this.execute});

  final String toolName;
  final String summary; // 展示给用户的变更摘要
  final Future<String> Function() execute; // 确认后执行，返回结果文本
}

class AgentToolResult {
  AgentToolResult.ok(this.text) : pendingAction = null;
  AgentToolResult.confirm(this.pendingAction)
      : text = null;
  AgentToolResult.error(this.text) : pendingAction = null;

  final String? text;
  final PendingAction? pendingAction;
}

class AgentTools {
  AgentTools({required this.library, required this.visionImageOfPath});

  final LibraryIndex library;

  /// 读取图片文件字节（供视觉模型）；由上层注入以复用缓存。
  final Future<List<int>> Function(String path) visionImageOfPath;

  final List<ToolSpec> specs = _specs;

  ToolSpec? specOf(String name) =>
      specs.where((s) => s.name == name).firstOrNull;

  static final List<ToolSpec> _specs = [
    ToolSpec(
      name: 'describe_image',
      description: '调用视觉模型生成图片描述：主体、场景、风格、可见文字。参数 path 为图片完整路径。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      needsConfirm: false,
    ),
    ToolSpec(
      name: 'ocr_image',
      description: '提取图片中的可见文字，返回文本内容。参数 path。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      needsConfirm: false,
    ),
    ToolSpec(
      name: 'tag_image',
      description: '为图片写入标签与标题（虚拟操作，只写本地库，不改真实文件）。参数 path, tags(字符串数组), title。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'tags': {'type': 'array', 'items': {'type': 'string'}},
          'title': {'type': 'string'},
        },
        'required': ['path', 'tags'],
      },
      needsConfirm: false,
    ),
    ToolSpec(
      name: 'organize_image',
      description: '为图片设置分类，图库按分类聚合展示（虚拟操作）。参数 path, category。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'category': {'type': 'string'},
        },
        'required': ['path', 'category'],
      },
      needsConfirm: false,
    ),
    ToolSpec(
      name: 'rename_batch',
      description: '依据识别结果批量重命名真实文件（危险操作，会先请求用户确认）。参数 renames 数组，元素 {path, newName}。',
      parameters: {
        'type': 'object',
        'properties': {
          'renames': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
                'newName': {'type': 'string'},
              },
            },
          },
        },
        'required': ['renames'],
      },
      needsConfirm: true,
    ),
    ToolSpec(
      name: 'ai_edit',
      description: '指令式编辑：把编辑要求编译为本地滤镜节点并写入图片编辑栈（如调成日系冷调）。生成式改图（背景替换等）当前版本不支持。参数 path, instruction。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'instruction': {'type': 'string'},
        },
        'required': ['path', 'instruction'],
      },
      needsConfirm: false,
    ),
    ToolSpec(
      name: 'search_images',
      description: '按关键词、标签、时间过滤图库，返回命中文件路径列表。参数 query。',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
      },
      needsConfirm: false,
    ),
  ];

  /// 执行模型决议。返回工具结果文本或待确认动作。
  Future<AgentToolResult> dispatch(String name, Map<String, Object?> args) async {
    switch (name) {
      case 'describe_image':
      case 'ocr_image':
        // 视觉调用由 AgentSession 处理（需要模型），此处不直达
        return AgentToolResult.error('工具 $name 应由会话层执行');

      case 'tag_image':
        final path = args['path'] as String?;
        final tags = (args['tags'] as List?)?.cast<String>() ?? const [];
        final title = args['title'] as String?;
        final entry = library.entryAt(path ?? '');
        if (entry == null) return AgentToolResult.error('图库中未找到：$path');
        for (final t in tags) {
          library.addTag(path!, t);
        }
        if (title != null && title.isNotEmpty) {
          library.setVirtualName(path!, title);
        }
        await library.flush();
        return AgentToolResult.ok('已为 ${entry.name} 写入标签 ${tags.join('、')}${title != null ? '，标题「$title」（虚拟）' : ''}');

      case 'organize_image':
        final path = args['path'] as String?;
        final category = args['category'] as String?;
        final entry = library.entryAt(path ?? '');
        if (entry == null) return AgentToolResult.error('图库中未找到：$path');
        library.setCategory(path!, category);
        await library.flush();
        return AgentToolResult.ok('已将 ${entry.name} 归入分类「$category」（虚拟）');

      case 'rename_batch':
        final renames = (args['renames'] as List?)
                ?.map((e) => (e as Map).cast<String, Object?>())
                .toList() ??
            const [];
        if (renames.isEmpty) return AgentToolResult.error('renames 为空');
        final lines = [
          for (final r in renames)
            '${_fileName(r['path'] as String? ?? '')} → ${r['newName']}'
        ];
        return AgentToolResult.confirm(PendingAction(
          toolName: 'rename_batch',
          summary: '将重命名 ${renames.length} 个文件：\n${lines.join('\n')}',
          execute: () async {
            final done = <String>[];
            for (final r in renames) {
              final p = r['path'] as String;
              final newName = r['newName'] as String;
              final dir = p.substring(0, p.lastIndexOf(Platform.pathSeparator));
              final target = '$dir${Platform.pathSeparator}$newName';
              await File(p).rename(target);
              library.setVirtualName(p, null);
              done.add(newName);
            }
            return '已完成 ${done.length} 个重命名';
          },
        ));

      case 'search_images':
        final query = args['query'] as String? ?? '';
        final hits = library.search(query);
        return AgentToolResult.ok(
            '命中 ${hits.length} 张：${hits.take(20).map((e) => e.path).join('；')}');

      case 'ai_edit':
        return AgentToolResult.error('ai_edit 应由会话层编译执行');

      default:
        return AgentToolResult.error('未知工具：$name');
    }
  }

  String _fileName(String p) =>
      p.split(Platform.pathSeparator).last;
}
