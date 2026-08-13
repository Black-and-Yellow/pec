import 'dart:typed_data';

import 'package:finguard/services/qr_image_decoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:zxing2/qrcode.dart';

void main() {
  group('QrImageDecoder', () {
    test('decodes a supported PNG QR image', () {
      const value =
          'upi://pay?pa=merchant%40okaxis&pn=Corner%20Shop&am=125.00&cu=INR';

      expect(QrImageDecoder.decode(_qrPng(value)), value);
    });

    test(
      'rejects an oversized PNG from header metadata before pixel decode',
      () {
        final bytes = _headerOnlyPng(width: 5000, height: 4000);

        expect(
          () => QrImageDecoder.decode(bytes),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('too large to scan safely'),
            ),
          ),
        );
      },
    );

    test('rejects maximum-width metadata without multiplying dimensions', () {
      final bytes = _headerOnlyPng(width: 0xffffffff, height: 0xffffffff);

      expect(
        () => QrImageDecoder.decode(bytes),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('too large to scan safely'),
          ),
        ),
      );
    });

    test('rejects invalid image bytes with a useful error', () {
      expect(
        () => QrImageDecoder.decode(Uint8List.fromList(<int>[1, 2, 3])),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'That file is not a supported image.',
          ),
        ),
      );
    });
  });
}

Uint8List _qrPng(String value) {
  final matrix = Encoder.encode(value, ErrorCorrectionLevel.m).matrix!;
  const scale = 6;
  const quietZone = 4;
  final dimension = (matrix.width + (quietZone * 2)) * scale;
  final qrImage = image.Image(width: dimension, height: dimension);

  for (var y = 0; y < dimension; y++) {
    for (var x = 0; x < dimension; x++) {
      qrImage.setPixelRgb(x, y, 255, 255, 255);
    }
  }
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      if (matrix.get(x, y) != 1) {
        continue;
      }
      final left = (x + quietZone) * scale;
      final top = (y + quietZone) * scale;
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          qrImage.setPixelRgb(left + dx, top + dy, 0, 0, 0);
        }
      }
    }
  }

  return image.encodePng(qrImage);
}

Uint8List _headerOnlyPng({required int width, required int height}) {
  final bytes = BytesBuilder(copy: false)
    ..add(<int>[137, 80, 78, 71, 13, 10, 26, 10])
    ..add(
      _pngChunk(
        'IHDR',
        (ByteData(13)
              ..setUint32(0, width)
              ..setUint32(4, height)
              ..setUint8(8, 8)
              ..setUint8(9, 2)
              ..setUint8(10, 0)
              ..setUint8(11, 0)
              ..setUint8(12, 0))
            .buffer
            .asUint8List(),
      ),
    )
    ..add(_pngChunk('IEND', Uint8List(0)));
  return bytes.takeBytes();
}

Uint8List _pngChunk(String type, Uint8List data) {
  final typeBytes = Uint8List.fromList(type.codeUnits);
  final crcInput = Uint8List.fromList(<int>[...typeBytes, ...data]);
  final chunk = ByteData(12 + data.length)
    ..setUint32(0, data.length)
    ..buffer.asUint8List().setRange(4, 8, typeBytes)
    ..buffer.asUint8List().setRange(8, 8 + data.length, data)
    ..setUint32(8 + data.length, _crc32(crcInput));
  return chunk.buffer.asUint8List();
}

int _crc32(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
