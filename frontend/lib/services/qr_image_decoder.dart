import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:zxing2/qrcode.dart';

abstract final class QrImageDecoder {
  static String decode(Uint8List bytes) {
    final image.Image? decoded = image.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('That file is not a supported image.');
    }
    final image.Image rgba = decoded.convert(numChannels: 4);
    final RGBLuminanceSource source = RGBLuminanceSource(
      rgba.width,
      rgba.height,
      rgba.getBytes(order: image.ChannelOrder.rgba).buffer.asInt32List(),
    );
    final BinaryBitmap bitmap = BinaryBitmap(HybridBinarizer(source));
    try {
      final Result result = QRCodeReader().decode(bitmap);
      final String value = result.text.trim();
      if (value.isEmpty) {
        throw const FormatException(
          'No readable QR code was found in that image.',
        );
      }
      return value;
    } on ReaderException {
      throw const FormatException(
        'No readable QR code was found. Try a sharper, tightly cropped image.',
      );
    }
  }
}
