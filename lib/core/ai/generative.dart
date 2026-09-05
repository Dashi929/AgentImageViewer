/// 生成式图像编辑（设计书 2.4：背景替换、对象消除、扩图 → 云端图像模型）。
///
/// 契约：OpenAI 兼容 `POST {baseUrl}/images/edits`（multipart/form-data），
/// 响应 `data[0].b64_json` 或 `data[0].url`。
/// 隐私红线（6.3）：调用前必须向用户明示将要上传的内容（确认卡片）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ai_client.dart';

class GenerativeConfig {
  GenerativeConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 180),
  });

  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;

  Uri get editsUri {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/images/edits');
  }
}

/// multipart/form-data 请求体构建（纯函数，可单测）。
({Uint8List body, String contentType}) buildEditMultipart({
  required String boundary,
  required String model,
  required String prompt,
  required List<int> imageBytes,
  String imageFilename = 'image.png',
}) {
  final bb = BytesBuilder();

  void field(String name, String value) {
    bb.add(utf8.encode('--$boundary\r\n'));
    bb.add(utf8.encode(
        'Content-Disposition: form-data; name="$name"\r\n\r\n$value\r\n'));
  }

  field('model', model);
  field('prompt', prompt);
  bb.add(utf8.encode('--$boundary\r\n'));
  bb.add(utf8.encode('Content-Disposition: form-data; name="image"; '
      'filename="$imageFilename"\r\n'));
  bb.add(utf8.encode('Content-Type: image/png\r\n\r\n'));
  bb.add(imageBytes);
  bb.add(utf8.encode('\r\n--$boundary--\r\n'));

  return (
    body: bb.toBytes(),
    contentType: 'multipart/form-data; boundary=$boundary',
  );
}

/// 判断指令是否属于生成式能力（与本地编译互斥）。纯函数。
bool isGenerativeInstruction(String instruction) {
  final ins = instruction.toLowerCase();
  return ins.contains('背景') ||
      ins.contains('消除') ||
      ins.contains('扩图') ||
      ins.contains('替换成') ||
      ins.contains('生成') ||
      (ins.contains('remove') && ins.contains('object')) ||
      ins.contains('outpaint');
}

class GenerativeEditResult {
  GenerativeEditResult(this.pngBytes);
  final Uint8List pngBytes;
}

class GenerativeClient {
  GenerativeClient(this.config);

  final GenerativeConfig config;
  HttpClient? _http;

  HttpClient get _http_ =>
      _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 30);

  Future<GenerativeEditResult> editImage({
    required List<int> imageBytes,
    required String prompt,
  }) async {
    final boundary =
        'aiv${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}${math.Random().nextInt(1 << 20)}';
    final mp = buildEditMultipart(
      boundary: boundary,
      model: config.model,
      prompt: prompt,
      imageBytes: imageBytes,
    );

    final req = await _http_.postUrl(config.editsUri);
    req.headers.set(HttpHeaders.contentTypeHeader, mp.contentType);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
    req.contentLength = mp.body.length;
    req.add(mp.body);

    final resp = await req.close().timeout(config.timeout);
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw AiException(_normalizeError(text), statusCode: resp.statusCode);
    }

    final json = jsonDecode(text) as Map;
    final data = json['data'] as List?;
    if (data == null || data.isEmpty) {
      throw AiException('生成结果为空：$text');
    }
    final first = data.first as Map;
    if (first['b64_json'] is String) {
      return GenerativeEditResult(
          base64Decode(first['b64_json'] as String));
    }
    if (first['url'] is String) {
      return GenerativeEditResult(await _download(first['url'] as String));
    }
    throw AiException('不支持的生成结果格式');
  }

  Future<Uint8List> _download(String url) async {
    final req = await _http_.getUrl(Uri.parse(url));
    final resp = await req.close().timeout(config.timeout);
    if (resp.statusCode != 200) throw AiException('下载生成结果失败');
    final bb = BytesBuilder();
    await for (final chunk in resp) {
      bb.add(chunk);
    }
    return bb.toBytes();
  }

  String _normalizeError(String body) {
    try {
      final j = jsonDecode(body) as Map;
      final err = j['error'];
      if (err is Map) return (err['message'] as String?) ?? '服务返回错误';
      if (err is String) return err;
    } catch (_) {}
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }

  void dispose() {
    _http?.close();
    _http = null;
  }
}
