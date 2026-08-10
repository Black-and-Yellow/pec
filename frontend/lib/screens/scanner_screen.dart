import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../config/app_config.dart';
import '../models/payment.dart';
import '../services/app_services.dart';
import '../services/image_validation.dart';
import '../services/qr_image_decoder.dart';
import '../theme/app_theme.dart';
import 'paste_screen.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final MobileScannerController _scannerController = MobileScannerController(
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final ImagePicker _imagePicker = ImagePicker();
  bool _handling = false;
  String? _error;

  @override
  void dispose() {
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.ink,
    appBar: AppBar(
      title: const Text('Scan payment QR'),
      backgroundColor: AppColors.ink,
      foregroundColor: Colors.white,
      actions: <Widget>[
        if (!kIsWeb)
          IconButton(
            tooltip: 'Toggle torch',
            onPressed: _scannerController.toggleTorch,
            icon: const Icon(Icons.flashlight_on_outlined),
          ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                MobileScanner(
                  controller: _scannerController,
                  onDetect: _onDetect,
                  errorBuilder:
                      (BuildContext context, MobileScannerException error) =>
                          _CameraError(message: error.errorDetails?.message),
                ),
                IgnorePointer(
                  child: Center(
                    child: Container(
                      width: 250,
                      height: 250,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 22,
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _handling
                          ? 'QR found. Checking format…'
                          : 'Hold the payment QR inside the frame',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            color: AppColors.canvas,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_error != null) ...<Widget>[
                  Text(
                    _error!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: AppColors.danger),
                  ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(
                  key: const Key('upload_qr_button'),
                  onPressed: _handling ? null : _pickQrImage,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(kIsWeb ? 'Upload QR image' : 'Choose QR image'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _handling ? null : _openPaste,
                  child: const Text('Paste a UPI link instead'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  void _onDetect(BarcodeCapture capture) {
    if (_handling) {
      return;
    }
    final String? value = _firstBarcodeValue(capture);
    if (value != null) {
      unawaited(_handleValue(value));
    }
  }

  Future<void> _pickQrImage() async {
    setState(() => _error = null);
    try {
      final XFile? file = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 92,
        requestFullMetadata: false,
      );
      if (file == null) {
        return;
      }
      final int length = await file.length();
      if (length > AppConfig.maxQrImageBytes) {
        throw const FormatException('Choose an image smaller than 5 MB.');
      }
      final Uint8List bytes = await file.readAsBytes();
      ImageValidation.enforceMaximumSize(bytes, AppConfig.maxQrImageBytes);
      ImageValidation.detectSupportedMimeType(bytes);
      setState(() => _handling = true);
      String? value;
      if (!kIsWeb) {
        final BarcodeCapture? capture = await _scannerController.analyzeImage(
          file.path,
        );
        value = capture == null ? null : _firstBarcodeValue(capture);
      }
      value ??= QrImageDecoder.decode(bytes);
      await _handleValue(value);
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _handling = false;
        _error = error.message.toString();
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _handling = false;
        _error =
            'The image could not be read. Try another image or paste the UPI link.';
      });
    }
  }

  String? _firstBarcodeValue(BarcodeCapture capture) {
    for (final Barcode barcode in capture.barcodes) {
      final String value = barcode.rawValue?.trim() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  Future<void> _handleValue(String value) async {
    if (_handling && mounted && _error == null) {
      // Image upload already set the progress state.
    } else if (mounted) {
      setState(() {
        _handling = true;
        _error = null;
      });
    }
    try {
      await _scannerController.stop();
      Payment.validateUpiUri(value);
      if (!mounted) {
        return;
      }
      await Navigator.pushReplacement<void, void>(
        context,
        MaterialPageRoute<void>(
          builder: (BuildContext context) => PasteScreen(
            services: widget.services,
            initialUri: value,
            analyzeImmediately: true,
          ),
        ),
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _handling = false;
        _error = '${error.message} No link was opened.';
      });
      try {
        await _scannerController.start();
      } on MobileScannerException {
        // Upload and paste remain available when camera access is unavailable.
      }
    }
  }

  void _openPaste() {
    Navigator.pushReplacement<void, void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            PasteScreen(services: widget.services),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.ink,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.no_photography_outlined,
              color: Colors.white,
              size: 42,
            ),
            const SizedBox(height: 14),
            Text(
              'Camera unavailable',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              message ??
                  'Allow camera access, upload a QR image, or paste the payment link.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
    ),
  );
}
