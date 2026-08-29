package org.pec.finguard

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "org.pec.finguard/share"
    private var channel: MethodChannel? = null
    private var pendingSharedText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingSharedText = extractSharedText(intent)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).also { created ->
            created.setMethodCallHandler { call, result ->
                if (call.method == "getInitialShare") {
                    result.success(pendingSharedText)
                    pendingSharedText = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractSharedText(intent)?.let { shared ->
            val activeChannel = channel
            if (activeChannel == null) {
                pendingSharedText = shared
            } else {
                activeChannel.invokeMethod("onShare", shared)
            }
        }
    }

    private fun extractSharedText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        if (intent.type != "text/plain") return null
        return try {
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.take(5_000)
        } catch (_: RuntimeException) {
            null
        }
    }
}
