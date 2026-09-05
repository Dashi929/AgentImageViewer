import 'dart:typed_data';

import 'package:agent_image_viewer/core/image/exif.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一个最小合法的 JPEG：FFD8 + APP1(Exif) + FFD9。
Uint8List buildJpegWithExif({
  required bool littleEndian,
  String make = 'TestCam',
  int orientation = 6,
  int iso = 100,
  (int, int) fNumber = (28, 10), // f/2.8
}) {
  final bo = littleEndian ? 'II' : 'MM';
  late ByteData Function(int) w16, w32;
  if (littleEndian) {
    w16 = (v) => (ByteData(2)..setUint16(0, v, Endian.little));
    w32 = (v) => (ByteData(4)..setUint32(0, v, Endian.little));
  } else {
    w16 = (v) => (ByteData(2)..setUint16(0, v, Endian.big));
    w32 = (v) => (ByteData(4)..setUint32(0, v, Endian.big));
  }

  // TIFF 布局：offset 0-1 序号，2-3 42，4-7 IFD0 偏移

  // 重新精确构造：offset 0-1 序号，2-3 42，4-7 IFD0 偏移
  final t = BytesBuilder();
  final head = BytesBuilder();
  head.add(bo.codeUnits);
  head.add(w16(42).buffer.asUint8List());
  const ifd0Off = 8;
  head.add(w32(ifd0Off).buffer.asUint8List());
  t.add(head.toBytes());

  // IFD0：3 个条目：Make(0x010F ASCII), Orientation(0x0112 SHORT), ExifIFD(0x8769 LONG)
  const nEntries = 3;
  final ifd0Size = 2 + nEntries * 12 + 4;
  int dataPtr = ifd0Off + ifd0Size; // 额外数据区起点

  final makeBytes = make.codeUnits + [0];
  final makeDataOff = dataPtr;
  dataPtr += makeBytes.length;
  // Exif IFD 在 Make 数据之后
  const exifEntries = 2;
  final exifOff = dataPtr;
  dataPtr += 2 + exifEntries * 12 + 4;
  final fnumDataOff = dataPtr;
  dataPtr += 8;

  final ifd = BytesBuilder();
  ifd.add(w16(nEntries).buffer.asUint8List());
  void entry(int tag, int type, int count, int value) {
    ifd.add(w16(tag).buffer.asUint8List());
    ifd.add(w16(type).buffer.asUint8List());
    ifd.add(w32(count).buffer.asUint8List());
    ifd.add(w32(value).buffer.asUint8List());
  }

  entry(0x010F, 2, makeBytes.length, makeDataOff); // ASCII → 偏移
  entry(0x0112, 3, 1, orientation); // SHORT 内联
  entry(0x8769, 4, 1, exifOff); // LONG → ExifIFD 偏移
  ifd.add(w32(0).buffer.asUint8List()); // 下一个 IFD = 0
  t.add(ifd.toBytes());

  // 额外数据：Make 字符串
  t.add(makeBytes);
  // Exif IFD：ISO(0x8827 SHORT) + FNumber(0x829D RATIONAL)
  final exif = BytesBuilder();
  exif.add(w16(exifEntries).buffer.asUint8List());
  void eentry(int tag, int type, int count, int value) {
    exif.add(w16(tag).buffer.asUint8List());
    exif.add(w16(type).buffer.asUint8List());
    exif.add(w32(count).buffer.asUint8List());
    exif.add(w32(value).buffer.asUint8List());
  }

  eentry(0x8827, 3, 1, iso); // SHORT 内联
  eentry(0x829D, 5, 1, fnumDataOff); // RATIONAL → 偏移
  exif.add(w32(0).buffer.asUint8List());
  t.add(exif.toBytes());

  final pad = makeBytes.length % 2 == 0 ? 0 : 1; // 保持对齐无所谓，构造时已按实际排
  // 按 dataPtr 布局补齐 Make 数据（上面 t 已写入 makeBytes；若奇数长度补齐到 fnum 位置）
  if (pad == 1) t.add([0]);
  final fnum = BytesBuilder();
  fnum.add(w32(fNumber.$1).buffer.asUint8List());
  fnum.add(w32(fNumber.$2).buffer.asUint8List());
  t.add(fnum.toBytes());

  final tiffBytes = t.toBytes();

  // 组 JPEG：FFD8 FFE1 <len> "Exif\0\0" <tiff> FFD9
  final jpeg = BytesBuilder();
  jpeg.add([0xFF, 0xD8]);
  final segLen = 2 + 6 + tiffBytes.length;
  jpeg.add([0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF]);
  jpeg.add('Exif'.codeUnits + [0, 0]);
  jpeg.add(tiffBytes);
  jpeg.add([0xFF, 0xD9]);
  return jpeg.toBytes();
}

void main() {
  test('解析小端 TIFF 的基础 EXIF 字段', () {
    final data = parseExif(buildJpegWithExif(littleEndian: true))!;
    expect(data.make, 'TestCam');
    expect(data.orientation, 6);
    expect(data.iso, 100);
    expect(data.fNumber, closeTo(2.8, 1e-6));
  });

  test('解析大端 TIFF（MM）', () {
    final data = parseExif(buildJpegWithExif(littleEndian: false))!;
    expect(data.make, 'TestCam');
    expect(data.orientation, 6);
    expect(data.iso, 100);
  });

  test('快门显示格式化', () {
    final d = ExifData()..exposureTimeSeconds = 0.004;
    expect(d.exposureDisplay, '1/250s');
    d.exposureTimeSeconds = 2.0;
    expect(d.exposureDisplay, '2.0s');
  });

  test('非 JPEG / 空数据返回 null 不抛异常', () {
    expect(parseExif(Uint8List.fromList([0x89, 0x50])), isNull); // PNG 头
    expect(parseExif(Uint8List(0)), isNull);
    // JPEG 头但无 EXIF 段
    expect(parseExif(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])), isNull);
  });
}
