import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:zxing2/qrcode.dart';

abstract final class QrImageDecoder {
  // Decoding and QR binarization each allocate buffers proportional to the
  // uncompressed image. Keep ordinary phone photos usable while preventing a
  // small compressed file from expanding without a fixed upper bound.
  static const int maximumPixels = 16 * 1024 * 1024;
  static const int _maximumDecodeDimension = 2048;

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

    final image.Image prepared = _prepare(decoded);
    String? value = _tryDecode(prepared);
    if (value != null) {
      return value;
    }

    // Payment-app QR images are often exported without a full quiet zone.
    final int shortestSide = prepared.width < prepared.height
        ? prepared.width
        : prepared.height;
    final int padding = (shortestSide ~/ 10).clamp(12, 256);
    final image.Image padded = image.copyExpandCanvas(
      prepared,
      padding: padding,
      backgroundColor: image.ColorRgb8(255, 255, 255),
    );
    value = _tryDecode(padded);
    if (value != null) {
      return value;
    }

    // On fallback only, remove dark strokes from a common centered brand mark
    // so the QR error-correction layer sees a bounded erasure region.
    final image.Image withoutCenterBrand = image.Image.from(
      padded,
      noAnimation: true,
    );
    final int brandSide = (shortestSide * 22) ~/ 100;
    final int left = (withoutCenterBrand.width - brandSide) ~/ 2;
    final int top = (withoutCenterBrand.height - brandSide) ~/ 2;
    image.fillRect(
      withoutCenterBrand,
      x1: left,
      y1: top,
      x2: left + brandSide - 1,
      y2: top + brandSide - 1,
      color: image.ColorRgb8(255, 255, 255),
    );
    value = _tryDecode(withoutCenterBrand);
    if (value != null) {
      return value;
    }

    for (final int angle in <int>[90, 180, 270]) {
      value = _tryDecode(image.copyRotate(withoutCenterBrand, angle: angle));
      if (value != null) {
        return value;
      }
    }

    throw const FormatException(
      'No readable QR code was found. Try a sharper image with some space around the code.',
    );
  }

  static image.Image _prepare(image.Image decoded) {
    if (decoded.width <= _maximumDecodeDimension &&
        decoded.height <= _maximumDecodeDimension) {
      return image.bakeOrientation(decoded);
    }
    if (decoded.width >= decoded.height) {
      return image.copyResize(decoded, width: _maximumDecodeDimension);
    }
    return image.copyResize(decoded, height: _maximumDecodeDimension);
  }

  static String? _tryDecode(image.Image candidate) {
    final image.Image rgba = candidate.convert(numChannels: 4);
    // zxing2 consumes 0xAARRGGBB pixels. BGRA bytes form that value on the
    // little-endian Web and Android targets.
    final Uint8List bgra = rgba.getBytes(order: image.ChannelOrder.bgra);
    final RGBLuminanceSource source = RGBLuminanceSource(
      rgba.width,
      rgba.height,
      bgra.buffer.asInt32List(bgra.offsetInBytes, rgba.width * rgba.height),
    );
    final DecodeHints harder = DecodeHints()
      ..put<void>(DecodeHintType.tryHarder);
    final DecodeHints pure = DecodeHints()
      ..put<void>(DecodeHintType.pureBarcode);
    final List<({Binarizer binarizer, DecodeHints hints})> attempts =
        <({Binarizer binarizer, DecodeHints hints})>[
          (binarizer: HybridBinarizer(source), hints: harder),
          (binarizer: HybridBinarizer(source), hints: pure),
          (binarizer: GlobalHistogramBinarizer(source), hints: harder),
          (
            binarizer: HybridBinarizer(InvertedLuminanceSource(source)),
            hints: harder,
          ),
        ];
    for (final attempt in attempts) {
      try {
        final Result result = QRCodeReader().decode(
          BinaryBitmap(attempt.binarizer),
          hints: attempt.hints,
        );
        final String value = result.text.trim();
        if (value.isNotEmpty) {
          return value;
        }
      } on ReaderException {
        // Try the next bounded preprocessing strategy.
      }
    }
    return null;
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
