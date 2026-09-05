/// 轻量 JPEG EXIF 解析（设计书 3.1：自研轻量解析，不引第三方库）。
///
/// 只解析浏览场景需要的字段：方向、相机、拍摄时间、光圈、快门、ISO、焦距。
/// 纯 Dart；非 JPEG 或无 EXIF 返回 null。
library;

import 'dart:typed_data';

class ExifData {
  int? orientation;
  String? make, model, dateTimeOriginal, lensModel;
  double? fNumber, exposureTimeSeconds, focalLengthMm;
  int? iso;

  String get exposureDisplay {
    final t = exposureTimeSeconds;
    if (t == null || t <= 0) return '-';
    return t >= 1 ? '${t.toStringAsFixed(1)}s' : '1/${(1 / t).round()}s';
  }

  String get apertureDisplay =>
      fNumber == null ? '-' : 'f/${fNumber!.toStringAsFixed(1)}';
}

/// 解析 JPEG 字节中的 EXIF。任何异常都以 null 收场，不抛穿。
ExifData? parseExif(Uint8List bytes) {
  try {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;

    var i = 2;
    Uint8List? tiff;
    while (i + 4 <= bytes.length) {
      if (bytes[i] != 0xFF) return null;
      final marker = bytes[i + 1];
      if (marker == 0xD9 || marker == 0xDA) break; // EOI / SOS
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      final segLen = (bytes[i + 2] << 8) | bytes[i + 3];
      if (marker == 0xE1 &&
          i + 10 <= bytes.length &&
          bytes[i + 4] == 0x45 /*E*/ &&
          bytes[i + 5] == 0x78 /*x*/ &&
          bytes[i + 6] == 0x69 /*i*/ &&
          bytes[i + 7] == 0x66 /*f*/ &&
          bytes[i + 8] == 0x00 &&
          bytes[i + 9] == 0x00) {
        tiff = Uint8List.sublistView(bytes, i + 10, i + 2 + segLen);
        break;
      }
      i += 2 + segLen;
    }
    if (tiff == null) return null;

    final bd = ByteData.sublistView(tiff);
    final little = tiff[0] == 0x49 && tiff[1] == 0x49;
    final endian = little ? Endian.little : Endian.big;
    if (!little && !(tiff[0] == 0x4D && tiff[1] == 0x4D)) return null;
    if (bd.getUint16(2, endian) != 42) return null;
    final ifd0Off = bd.getUint32(4, endian);
    if (ifd0Off + 2 > tiff.length) return null;

    String? make, model, dateTimeOriginal, lensModel;
    int? orientation, iso;
    double? fNumber, exposure, focal;

    final tags0 = _readIfd(bd, ifd0Off, endian);
    int? exifIfdOff, gpsIfdOff;
    for (final t in tags0) {
      switch (t.tag) {
        case 0x010F:
          make = _ascii(t, bd);
        case 0x0110:
          model = _ascii(t, bd);
        case 0x0112:
          orientation = t.value;
        case 0x8769:
          exifIfdOff = t.value;
        case 0x8825:
          gpsIfdOff = t.value;
      }
    }

    if (exifIfdOff != null) {
      for (final t in _readIfd(bd, exifIfdOff, endian)) {
        switch (t.tag) {
          case 0x9003:
          case 0x0132:
            dateTimeOriginal ??= _ascii(t, bd);
          case 0x829A:
            exposure ??= _rational(t, bd, endian);
          case 0x829D:
            fNumber = _rational(t, bd, endian);
          case 0x8827:
            iso = t.value;
          case 0x920A:
            focal = _rational(t, bd, endian);
          case 0xA434:
            lensModel = _ascii(t, bd);
        }
      }
    }
    gpsIfdOff; // GPS 暂不解析，S4 场景再补

    if (make == null &&
        model == null &&
        orientation == null &&
        dateTimeOriginal == null &&
        fNumber == null) {
      return null;
    }
    return ExifData()
      ..orientation = orientation
      ..make = make
      ..model = model
      ..dateTimeOriginal = dateTimeOriginal
      ..lensModel = lensModel
      ..iso = iso
      ..fNumber = fNumber
      ..exposureTimeSeconds = exposure
      ..focalLengthMm = focal;
  } catch (_) {
    return null;
  }
}

class _IfdEntry {
  _IfdEntry(this.tag, this.type, this.count, this.valueOffsetOrValue, this.dataOffset);
  final int tag, type, count;
  final int valueOffsetOrValue;
  final int dataOffset; // 值在 TIFF 数据中的绝对偏移（内联时同 valueOffsetOrValue）

  /// 字段值（SHORT/LONG 内联时）。
  int get value => valueOffsetOrValue;
}

const _typeSizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8};

List<_IfdEntry> _readIfd(ByteData bd, int off, Endian endian) {
  if (off + 2 > bd.lengthInBytes) return const [];
  final n = bd.getUint16(off, endian);
  if (n > 512) return const [];
  final out = <_IfdEntry>[];
  var p = off + 2;
  for (var k = 0; k < n && p + 12 <= bd.lengthInBytes; k++) {
    final tag = bd.getUint16(p, endian);
    final type = bd.getUint16(p + 2, endian);
    final count = bd.getUint32(p + 4, endian);
    final size = (_typeSizes[type] ?? 0) * count;
    final inline = size <= 4;
    final raw = bd.getUint32(p + 8, endian);
    final val = (inline && type == 3) ? (raw & 0xFFFF) : raw;
    out.add(_IfdEntry(tag, type, count, val, val));
    p += 12;
  }
  return out;
}

String? _ascii(_IfdEntry t, ByteData bd) {
  if (t.type != 2) return null;
  final end = (t.dataOffset + t.count).clamp(0, bd.lengthInBytes);
  final codes = Uint8List.sublistView(bd, t.dataOffset, end);
  final s = String.fromCharCodes(codes.where((c) => c != 0)).trim();
  return s.isEmpty ? null : s;
}

double? _rational(_IfdEntry t, ByteData bd, Endian endian) {
  if ((t.type != 5 && t.type != 10) || t.count < 1) return null;
  final off = t.dataOffset;
  if (off + 8 > bd.lengthInBytes) return null;
  final numr =
      t.type == 5 ? bd.getUint32(off, endian) : bd.getInt32(off, endian);
  final den =
      t.type == 5 ? bd.getUint32(off + 4, endian) : bd.getInt32(off + 4, endian);
  if (den == 0) return null;
  return numr / den;
}
