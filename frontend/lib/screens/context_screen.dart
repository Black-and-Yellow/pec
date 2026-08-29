import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../config/app_config.dart';
import '../models/context_analysis.dart';
import '../services/api_service.dart';
import '../services/app_services.dart';
import '../services/image_validation.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'paste_screen.dart';

class ContextScreen extends StatefulWidget {
  const ContextScreen({required this.services, super.key, this.initialText});

  final AppServices services;
  final String? initialText;

  @override
  State<ContextScreen> createState() => _ContextScreenState();
}

class _ContextScreenState extends State<ContextScreen> {
  late final TextEditingController _controller;
  final ImagePicker _imagePicker = ImagePicker();
  bool _loading = false;
  bool _consentToExternalAi = false;
  String? _error;
  ContextAnalysis? _analysis;
  Uint8List? _screenshotBytes;
  String? _screenshotMimeType;
  String? _screenshotName;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _controller.addListener(_invalidateEditedAnalysis);
  }

  @override
  void dispose() {
    _controller.removeListener(_invalidateEditedAnalysis);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Check suspicious message')),
    body: PageBody(
      maxWidth: 760,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Look for scam context',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'Local rules and optional language analysis can identify pressure, impersonation and KYC threats. They never decide the final risk score.',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: 24),
          TextField(
            key: const Key('suspicious_message_field'),
            controller: _controller,
            enabled: !_loading,
            minLines: 6,
            maxLines: 10,
            maxLength: AppConfig.maxContextLength,
            decoration: const InputDecoration(
              labelText: 'Message text',
              hintText: 'Paste the message exactly as received…',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('choose_context_screenshot_button'),
            onPressed: _loading ? null : _pickScreenshot,
            icon: const Icon(Icons.image_outlined),
            label: Text(
              _screenshotBytes == null
                  ? 'Choose message screenshot'
                  : 'Replace message screenshot',
            ),
          ),
          if (_screenshotBytes != null) ...<Widget>[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.image_outlined, color: AppColors.tealDark),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${_screenshotName ?? 'Selected screenshot'} · ${_formatBytes(_screenshotBytes!.length)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove screenshot',
                    onPressed: _loading ? null : _removeScreenshot,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          const PrivacyNote(
            text:
                'Your selected text or image goes to the FinGuard server only when you press Analyze message. The app does not save screenshots. Gemini receives the input only if you opt in below.',
          ),
          const SizedBox(height: 10),
          CheckboxListTile(
            key: const Key('gemini_consent_checkbox'),
            value: _consentToExternalAi,
            onChanged: _loading
                ? null
                : (bool? value) {
                    setState(() => _consentToExternalAi = value ?? false);
                  },
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow optional Gemini analysis'),
            subtitle: const Text(
              'If enabled, the server may send this selected message or screenshot to Gemini. If you continue to a payment check, it may also send the final signal labels and payment note for optional explanation wording. You can leave this off and use deterministic local wording.',
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 16),
            ErrorNotice(message: _error!, onRetry: _analyze),
          ],
          const SizedBox(height: 20),
          AsyncFilledButton(
            buttonKey: const Key('analyze_message_button'),
            loading: _loading,
            onPressed: _analyze,
            icon: Icons.manage_search,
            label: 'Analyze message',
            loadingLabel: 'Analyzing message…',
            loadingSemanticsLabel: 'Analyzing message',
          ),
          if (_analysis != null) ...<Widget>[
            const SizedBox(height: 28),
            _AnalysisResult(analysis: _analysis!),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openPaymentCheck,
                icon: const Icon(Icons.arrow_forward),
                label: Text(
                  _analysis!.hasValidatedContext
                      ? 'Check a UPI request with this context'
                      : 'Check a UPI request without context',
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Future<void> _analyze() async {
    final String text = _controller.text.trim();
    if (text.isEmpty && _screenshotBytes == null) {
      setState(() => _error = 'Paste a message or choose a screenshot first.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _analysis = null;
    });
    try {
      final ContextAnalysis result = await widget.services.api.analyzeContext(
        text: text,
        screenshotBytes: _screenshotBytes,
        screenshotMimeType: _screenshotMimeType,
        consentToExternalAi: _consentToExternalAi,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _analysis = result;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _analysis = ContextAnalysis(
          available: false,
          sourceText: text,
          flags: const <String, bool>{},
          unavailableReason: error.message,
          source: ContextAnalysisSource.none,
          serviceMessage: error.message,
        );
      });
    }
  }

  Future<void> _pickScreenshot() async {
    setState(() => _error = null);
    try {
      final XFile? file = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 90,
        requestFullMetadata: false,
      );
      if (file == null) {
        return;
      }
      final int length = await file.length();
      if (length > AppConfig.maxContextImageBytes) {
        throw const FormatException('Choose a screenshot no larger than 2 MB.');
      }
      final Uint8List bytes = await file.readAsBytes();
      ImageValidation.enforceMaximumSize(bytes, AppConfig.maxContextImageBytes);
      final String mimeType = ImageValidation.detectSupportedMimeType(bytes);
      if (!mounted) {
        return;
      }
      setState(() {
        _screenshotBytes = bytes;
        _screenshotMimeType = mimeType;
        _screenshotName = file.name;
        _analysis = null;
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _error = error.message.toString());
      }
    } on Object {
      if (mounted) {
        setState(() {
          _error =
              'The screenshot could not be read. Choose a PNG, JPEG or WebP image.';
        });
      }
    }
  }

  void _removeScreenshot() {
    setState(() {
      _screenshotBytes = null;
      _screenshotMimeType = null;
      _screenshotName = null;
      _analysis = null;
    });
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes bytes';
    }
    return '${(bytes / 1024).ceil()} KB';
  }

  void _openPaymentCheck() {
    final ContextAnalysis? analysis = _analysis;
    if (analysis == null) {
      return;
    }
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PasteScreen(
          services: widget.services,
          contextAnalysis: analysis.hasValidatedContext ? analysis : null,
          consentToExternalAi: _consentToExternalAi,
        ),
      ),
    );
  }

  void _invalidateEditedAnalysis() {
    if (_analysis != null && mounted) {
      setState(() => _analysis = null);
    }
  }
}

class _AnalysisResult extends StatelessWidget {
  const _AnalysisResult({required this.analysis});

  final ContextAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final bool hasValidatedContext = analysis.hasValidatedContext;
    final List<String> labels = hasValidatedContext
        ? analysis.detectedLabels
        : const <String>[];
    final bool usedGemini = analysis.source == ContextAnalysisSource.gemini;
    final bool usedLocalRules =
        analysis.source == ContextAnalysisSource.localRules;
    return Semantics(
      key: const Key('context_analysis_result'),
      container: true,
      liveRegion: true,
      label: hasValidatedContext
          ? 'Message analysis complete'
          : 'Message analysis unavailable',
      child: WorkspacePanel(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  usedGemini
                      ? Icons.cloud_done_outlined
                      : Icons.offline_bolt_outlined,
                  color: usedGemini ? AppColors.teal : AppColors.caution,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    usedGemini
                        ? 'Gemini context signals'
                        : usedLocalRules
                        ? 'Local fallback signals'
                        : 'Context analysis unavailable',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              !hasValidatedContext
                  ? 'No validated context signal will be included in deterministic scoring.'
                  : labels.isEmpty
                  ? 'No supported scam-language signal was confidently detected.'
                  : '${labels.length} signal${labels.length == 1 ? '' : 's'} detected. These become inputs to deterministic scoring.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
            ),
            if ((analysis.serviceMessage ?? analysis.unavailableReason ?? '')
                .isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                analysis.serviceMessage ?? analysis.unavailableReason!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (hasValidatedContext && analysis.confidence != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '${_confidenceLabel(analysis.confidence!)} extraction confidence',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
              ),
            ],
            if (labels.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              for (final String label in labels)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: <Widget>[
                      const Icon(
                        Icons.flag_outlined,
                        size: 20,
                        color: AppColors.caution,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(label)),
                    ],
                  ),
                ),
            ],
            if (hasValidatedContext &&
                (analysis.explanation ?? '').isNotEmpty) ...<Widget>[
              const Divider(height: 28),
              Text(analysis.explanation!),
            ],
          ],
        ),
      ),
    );
  }

  String _confidenceLabel(double confidence) {
    if (confidence >= 0.8) {
      return 'High';
    }
    if (confidence >= 0.55) {
      return 'Moderate';
    }
    return 'Low';
  }
}
