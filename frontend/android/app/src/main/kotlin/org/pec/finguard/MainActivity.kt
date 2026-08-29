package org.pec.finguard

import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "org.pec.finguard/share"
    private val threatChannelName = "org.pec.finguard/threat"
    private var channel: MethodChannel? = null
    private var pendingSharedText: String? = null

    /**
     * Remote-desktop packages mapped to the fixed identifiers the backend
     * risk policy understands. Every entry must also appear in the manifest
     * <queries> allowlist or Android 11+ reports it as not installed.
     */
    private val remoteAccessPackages: Map<String, String> = mapOf(
        "com.anydesk.anydeskandroid" to "ANYDESK",
        "com.teamviewer.quicksupport.market" to "TEAMVIEWER",
        "com.teamviewer.quicksupport.addon.universal" to "TEAMVIEWER",
        "com.teamviewer.host.market" to "TEAMVIEWER",
        "com.teamviewer.teamviewer.market.mobile" to "TEAMVIEWER",
        "com.carriez.flutter_hbb" to "RUSTDESK",
        "com.sand.airdroid" to "AIRDROID",
        "com.sand.aircast" to "AIRDROID",
    )

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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            threatChannelName,
        ).setMethodCallHandler { call, result ->
            if (call.method == "detectRemoteAccessTools") {
                result.success(detectRemoteAccessTools())
            } else {
                result.notImplemented()
            }
        }
    }

    /**
     * Reports which known remote-access tools are installed. Detection failure
     * is never fatal: an empty list degrades to the ordinary risk check rather
     * than blocking a payment safety result.
     */
    private fun detectRemoteAccessTools(): List<String> {
        val detected = LinkedHashSet<String>()
        for ((packageName, toolId) in remoteAccessPackages) {
            try {
                packageManager.getPackageInfo(packageName, 0)
                detected.add(toolId)
            } catch (_: PackageManager.NameNotFoundException) {
                // Not installed: the ordinary, safe case.
            } catch (_: RuntimeException) {
                // A lookup failure must not break the payment check.
            }
        }
        return detected.toList()
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
