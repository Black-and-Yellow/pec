import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:zxing2/qrcode.dart';

abstract final class QrImageDecoder {
  // Decoding and QR binarization each allocate buffers proportional to the
  // uncompressed image. Keep ordinary phone photos usable while preventing a
  // small compressed file from expanding without a fixed upper bound.
  static const int maximumPixels = 16 * 1024 * 1024;

  static String decode(Uint8List bytes) {
    final image.Decoder? decoder;
    final image.DecodeInfo? info;
    try {
      decoder = image.findDecoderForData(bytes);
      info = decoder?.startDecode(bytes);
    } on Object {
      throw const FormatException('That file is not a supported image.');
    }

    if (decoder == null || info == null) {
      throw const FormatException('That file is not a supported image.');
    }
    _checkDimensions(info.width, info.height);

    final image.Image? decoded;
    try {
      // Decode only the first frame. QR scanning does not need an entire
      // animation, and startDecode exposed its canvas dimensions above.
      decoded = decoder.decodeFrame(0);
    } on Object {
      throw const FormatException('That file is not a supported image.');
    }
    if (decoded == null) {
      throw const FormatException('That file is not a supported image.');
    }
    // Defend against a decoder whose frame dimensions differ from its header
    // metadata. The header check is the pre-allocation guard; this is a final
    // invariant before allocating the RGBA and luminance buffers.
    _checkDimensions(decoded.width, decoded.height);

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

  static void _checkDimensions(int width, int height) {
    // Division avoids multiplying attacker-controlled dimensions, so the
    // check remains correct on platforms with fixed-width or JS integers.
    if (width <= 0 || height <= 0 || width > maximumPixels ~/ height) {
      throw const FormatException(
        'That image is too large to scan safely. Choose a smaller image.',
      );
    }
  }
}
