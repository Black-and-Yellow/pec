package org.pec.finguard

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "org.pec.finguard/share"
    private val threatChannelName = "org.pec.finguard/threat"
    private var channel: MethodChannel? = null
    private var pendingSharedText: String? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

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
            when (call.method) {
                "detectRemoteAccessTools" -> result.success(detectRemoteAccessTools())
                "readCallActivity" -> result.success(readCallActivity())
                "hasCallStatePermission" -> result.success(hasCallStatePermission())
                "requestCallStatePermission" -> requestCallStatePermission(result)
                else -> result.notImplemented()
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

    /**
     * Reads whether a call is in progress, once, at the moment of a check.
     *
     * Two independent readings, because neither alone is sufficient:
     *
     *  - The audio mode needs no permission and is the only one of the two
     *    that sees a WhatsApp or Telegram call, which is how most Indian
     *    payment fraud is actually talked through.
     *  - The telephony call state needs READ_PHONE_STATE, and in exchange
     *    reports a cellular call precisely and distinguishes a ringing one.
     *
     * The telephony reading wins when it is available and says something,
     * because it is the more specific of the two. Without the permission the
     * audio mode still carries the feature, so the whole thing degrades to
     * "slightly less precise" rather than to nothing.
     *
     * This is a snapshot, not a subscription. Nothing here runs in the
     * background, and a call that starts after a result is on screen is
     * invisible to it.
     */
    private fun readCallActivity(): String {
        telephonyCallActivity()?.let { return it }
        return audioModeCallActivity()
    }

    private fun telephonyCallActivity(): String? {
        if (!hasCallStatePermission()) return null
        return try {
            val telephony = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                ?: return null
            @Suppress("DEPRECATION")
            when (telephony.callState) {
                TelephonyManager.CALL_STATE_OFFHOOK -> "CELLULAR"
                TelephonyManager.CALL_STATE_RINGING -> "RINGING"
                else -> null
            }
        } catch (_: SecurityException) {
            // The permission can be revoked between the check and the read.
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun audioModeCallActivity(): String = try {
        val audio = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        when (audio?.mode) {
            AudioManager.MODE_IN_CALL -> "CELLULAR"
            AudioManager.MODE_IN_COMMUNICATION -> "VOICE_OVER_IP"
            AudioManager.MODE_RINGTONE -> "RINGING"
            else -> "NONE"
        }
    } catch (_: RuntimeException) {
        "NONE"
    }

    private fun hasCallStatePermission(): Boolean = checkSelfPermission(
        Manifest.permission.READ_PHONE_STATE,
    ) == PackageManager.PERMISSION_GRANTED

    private fun requestCallStatePermission(result: MethodChannel.Result) {
        if (hasCallStatePermission()) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            // A second prompt cannot be shown over the first. Report the
            // current state rather than leaving the caller waiting forever.
            result.success(false)
            return
        }
        pendingPermissionResult = result
        try {
            requestPermissions(
                arrayOf(Manifest.permission.READ_PHONE_STATE),
                CALL_STATE_PERMISSION_REQUEST,
            )
        } catch (_: RuntimeException) {
            pendingPermissionResult = null
            result.success(false)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CALL_STATE_PERMISSION_REQUEST) return
        val pending = pendingPermissionResult ?: return
        pendingPermissionResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending.success(granted)
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

    private companion object {
        const val CALL_STATE_PERMISSION_REQUEST = 4711
    }
}
