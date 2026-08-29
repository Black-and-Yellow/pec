import 'dart:typed_data';

abstract final class ImageValidation {
  static String detectSupportedMimeType(Uint8List bytes) {
    if (_startsWith(bytes, const <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ])) {
      return 'image/png';
    }
    if (_startsWith(bytes, const <int>[0xFF, 0xD8, 0xFF])) {
      return 'image/jpeg';
    }
    if (bytes.length >= 12 &&
        _asciiAt(bytes, 0, 'RIFF') &&
        _asciiAt(bytes, 8, 'WEBP')) {
      return 'image/webp';
    }
    throw const FormatException(
      'Choose a PNG, JPEG or WebP image. The file contents did not match a supported image type.',
    );
  }

  static void enforceMaximumSize(Uint8List bytes, int maximumBytes) {
    if (bytes.isEmpty) {
      throw const FormatException('The selected image is empty.');
    }
    if (bytes.length > maximumBytes) {
      final String maximumMb = (maximumBytes / (1024 * 1024)).toStringAsFixed(
        1,
      );
      throw FormatException('Choose an image no larger than $maximumMb MB.');
    }
  }

  static bool _startsWith(Uint8List bytes, List<int> signature) {
    if (bytes.length < signature.length) {
      return false;
    }
    for (int index = 0; index < signature.length; index += 1) {
      if (bytes[index] != signature[index]) {
        return false;
      }
    }
    return true;
  }

  static bool _asciiAt(Uint8List bytes, int offset, String value) {
    if (bytes.length < offset + value.length) {
      return false;
    }
    for (int index = 0; index < value.length; index += 1) {
      if (bytes[offset + index] != value.codeUnitAt(index)) {
        return false;
      }
    }
    return true;
  }
}
