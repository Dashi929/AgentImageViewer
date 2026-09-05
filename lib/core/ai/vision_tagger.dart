/// 视觉打标器（设计书 2.4 tag_image / 场景三：批量识别→标签+标题）。
///
/// 让视觉模型输出 JSON（容忍 ```json 围栏），解析失败抛 [FormatException]。
library;

import 'dart:convert';

import 'ai_client.dart';

class TagResult {
  TagResult(this.tags, this.title);
  final List<String> tags;
  final String title;
}

const tagPrompt =
    '识别这张图片，只输出一个 JSON 对象：{"tags": ["标签1","标签2"], "title": "简短标题"}。'
    '标签 2~5 个，中文。不要输出其他任何内容。';

/// 解析模型输出为 TagResult（纯函数，可单测）。
TagResult parseTagJson(String raw) {
  var t = raw.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
  final m = fence.firstMatch(t);
  if (m != null) t = m.group(1)!.trim();
  final start = t.indexOf('{');
  final end = t.lastIndexOf('}');
  if (start < 0 || end <= start) {
    throw const FormatException('输出中没有 JSON 对象');
  }
  final json = jsonDecode(t.substring(start, end + 1)) as Map;
  final tags = (json['tags'] as List? ?? [])
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .take(8)
      .toList();
  final title = (json['title'] as String?)?.trim() ?? '';
  if (tags.isEmpty && title.isEmpty) {
    throw const FormatException('JSON 中没有有效标签');
  }
  return TagResult(tags, title);
}

class VisionTagger {
  VisionTagger(this.client);

  final ChatBackend client;

  /// 对一张图打标。返回 null 表示图片读取失败。
  Future<TagResult?> tagImage(List<int> imageBytes) async {
    final resp = await client.chat(messages: [
      ChatMessage.user(tagPrompt, images: [imageBytes]),
    ], temperature: 0.2);
    return parseTagJson(resp.message.text);
  }
}
