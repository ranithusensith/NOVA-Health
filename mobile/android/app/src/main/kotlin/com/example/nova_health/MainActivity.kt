package com.example.nova_health

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel

// Health Connect shows its permission screen from a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nova_health/emergency")
            .setMethodCallHandler { call, result ->
                if (call.method != "openSms") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val phone = call.argument<String>("phone")
                val body = call.argument<String>("body")
                if (phone == null || body == null || !phone.matches(Regex("\\+?[0-9]{7,15}"))) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$phone"))
                    .putExtra("sms_body", body)
                try {
                    startActivity(intent)
                    result.success(true)
                } catch (_: ActivityNotFoundException) {
                    result.success(false)
                } catch (_: SecurityException) {
                    result.success(false)
                }
            }
    }
}
