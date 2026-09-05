#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地 OpenAI 兼容 Mock 服务（模拟器 AI 全流程测试用）。

chat/completions：第一轮返回 tag_image 工具调用，第二轮返回 describe 文本，
第三轮返回最终总结。
images/edits：返回一张 2x2 PNG（b64_json）。
监听 0.0.0.0:8000，模拟器经 10.0.2.2:8000 访问。
"""
import base64
import json
import struct
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 最小合法 PNG：1x1 蓝色像素
def make_png():
    def chunk(typ, data):
        c = typ + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
    idat = chunk(b'IDAT', zlib.compress(b'\x00' + b'\x40\x90\xE8' * 1))
    iend = chunk(b'IEND', b'')
    return b'\x89PNG\r\n\x1a\n' + ihdr + idat + iend

PNG_B64 = base64.b64encode(make_png()).decode()

TOOL_CALL_TAG = {
    'choices': [{
        'finish_reason': 'tool_calls',
        'message': {
            'role': 'assistant',
            'content': '',
            'tool_calls': [{
                'id': 'mock-1',
                'type': 'function',
                'function': {
                    'name': 'tag_image',
                    'arguments': json.dumps({
                        'tags': ['测试', '模拟器'],
                        'title': 'Mock 标题',
                        'path': '__CURRENT__',
                    }, ensure_ascii=False),
                },
            }],
        },
    }]
}

VISION_DESC = {
    'choices': [{
        'finish_reason': 'stop',
        'message': {'role': 'assistant', 'content': '（Mock 视觉）这是一张测试图片，主体为纯色渐变，无可见文字。'},
    }]
}

FINAL = {
    'choices': [{
        'finish_reason': 'stop',
        'message': {'role': 'assistant', 'content': '（Mock）已为当前图片写入标签「测试、模拟器」和虚拟标题。'},
    }]
}

GENERATIVE_CONFIRM_TEXT = {
    'choices': [{
        'finish_reason': 'tool_calls',
        'message': {
            'role': 'assistant',
            'content': '',
            'tool_calls': [{
                'id': 'mock-2',
                'type': 'function',
                'function': {
                    'name': 'ai_edit',
                    'arguments': json.dumps({
                        'path': '__CURRENT__',
                        'instruction': '把背景替换成沙滩',
                    }, ensure_ascii=False),
                },
            }],
        },
    }]
}


class Handler(BaseHTTPRequestHandler):
    call_count = {'chat': 0, 'edit': 0}

    def log_message(self, fmt, *args):
        print('[mock]', fmt % args)

    def _send(self, obj):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(length)
        path = self.path
        if path.endswith('/chat/completions'):
            req = json.loads(raw.decode('utf-8'))
            last_user = ''
            for m in req.get('messages', []):
                if m.get('role') == 'user':
                    c = m.get('content')
                    last_user = c if isinstance(c, str) else str(c)
            # 当前图上下文已由面板注入路径，替换占位
            TOOL_CALL_TAG['choices'][0]['message']['tool_calls'][0]['function']['arguments'] = json.dumps(
                {'tags': ['测试', '模拟器'], 'title': 'Mock 标题', 'path': _extract_path(last_user)},
                ensure_ascii=False)
            n = Handler.call_count['chat']
            Handler.call_count['chat'] += 1
            # 计数器模式：0 打标 → 1 视觉描述 → 2 总结 → 3 生成式确认 → 4 总结
            branch = n % 5
            if branch == 0:
                self._send(TOOL_CALL_TAG)
            elif branch == 1:
                self._send(VISION_DESC)
            elif branch == 2:
                self._send(FINAL)
            elif branch == 3:
                gen = json.loads(json.dumps(GENERATIVE_CONFIRM_TEXT))
                fn = gen['choices'][0]['message']['tool_calls'][0]['function']
                fn['arguments'] = fn['arguments'].replace('__CURRENT__', _extract_path(last_user))
                self._send(gen)
            else:
                self._send(FINAL)
            return
        if path.endswith('/images/edits'):
            self._send({'data': [{'b64_json': PNG_B64}]})
            return
        self.send_response(404)
        self.end_headers()


def _extract_path(text):
    import re
    m = re.search(r'（上下文：当前正在查看 (.+?)）', text)
    if m:
        return m.group(1)
    return '/data/data/com.dashi929.agent_image_viewer/files/testpics/sunset.jpg'


if __name__ == '__main__':
    print('mock AI server on 0.0.0.0:8000')
    ThreadingHTTPServer(('0.0.0.0', 8000), Handler).serve_forever()
