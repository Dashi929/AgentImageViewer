# -*- coding: utf-8 -*-
"""性能基准样张生成（设计书 3.3 验收口径 / 7.2 性能专项）。

产物（不入库，bench/ 在 .gitignore）：
- bench/huge.jpg      12000x9000（约 1.08 亿像素）JPEG，亿像素首屏基准
- bench/many/         10000 张小图副本，万张文件夹扫描基准

用法：python tool/gen_bench_images.py
验证：AIV_BENCH=1 flutter test test/bench_test.dart
"""
import os
import shutil

try:
    from PIL import Image
except ImportError:
    raise SystemExit('需要 Pillow：pip install pillow')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, 'bench')
MANY = os.path.join(BENCH, 'many')


def gen_huge():
    path = os.path.join(BENCH, 'huge.jpg')
    if os.path.exists(path):
        print('skip', path)
        return
    im = Image.new('RGB', (12000, 9000))
    px = im.load()
    # 稀疏渐变填充（避免逐像素过慢）：每 24px 一格
    for y in range(0, 9000, 24):
        g = int(y / 9000 * 255)
        for x in range(0, 12000, 24):
            px[x, y] = (x % 256, g, (x + y) % 256)
    im = im.resize((12000, 9000))
    im.save(path, quality=85)
    print('ok', path, os.path.getsize(path) // 1024, 'KB')


def gen_many(n=10000):
    os.makedirs(MANY, exist_ok=True)
    src = os.path.join(BENCH, 'seed.jpg')
    if not os.path.exists(src):
        Image.new('RGB', (800, 600), (60, 120, 90)).save(src, quality=80)
    for i in range(n):
        dst = os.path.join(MANY, f'img{i:05d}.jpg')
        if not os.path.exists(dst):
            shutil.copyfile(src, dst)
        if i % 2000 == 0:
            print('...', i)
    print('ok', MANY, n, 'files')


if __name__ == '__main__':
    os.makedirs(BENCH, exist_ok=True)
    gen_huge()
    gen_many()
