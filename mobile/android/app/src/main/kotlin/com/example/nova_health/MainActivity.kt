package com.example.nova_health

import android.content.Intent
import android.net.Uri
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

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
                val arguments = call.arguments as? Map<*, *>
                val phone = arguments?.get("phone") as? String
                val body = arguments?.get("body") as? String
                if (phone == null || body == null || !phone.matches(Regex("\\+?[0-9]{7,15}"))) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                try {
                    val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$phone"))
                        .putExtra("sms_body", body)
                    startActivity(intent)
                    result.success(true)
                } catch (_: Exception) {
                    // Native channel errors can otherwise log an Intent containing patient data.
                    result.success(false)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nova_health/health_connect")
            .setMethodCallHandler { call, result ->
                if (call.method != "readHeartRate") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val arguments = call.arguments as? Map<*, *>
                val start = arguments?.get("start") as? Number
                val end = arguments?.get("end") as? Number
                if (start == null || end == null || start.toLong() >= end.toLong()) {
                    result.error("INVALID_RANGE", "Invalid heart rate query range.", null)
                    return@setMethodCallHandler
                }
                lifecycleScope.launch {
                    try {
                        result.success(readHeartRate(start.toLong(), end.toLong()))
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        // The upstream plugin logs the raw exception from this query.
                        result.error("HEART_RATE_UNAVAILABLE", "Could not read heart rate.", null)
                    }
                }
            }
    }

    private suspend fun readHeartRate(start: Long, end: Long): List<Map<String, Long>> {
        val client = HealthConnectClient.getOrCreate(this)
        val range = TimeRangeFilter.between(Instant.ofEpochMilli(start), Instant.ofEpochMilli(end))
        val samples = mutableListOf<Map<String, Long>>()
        var pageToken: String? = null
        do {
            val page = client.readRecords(ReadRecordsRequest(
                recordType = HeartRateRecord::class,
                timeRangeFilter = range,
                pageToken = pageToken,
            ))
            for (record in page.records) {
                for (sample in record.samples) {
                    samples.add(mapOf("at" to sample.time.toEpochMilli(), "bpm" to sample.beatsPerMinute))
                }
            }
            pageToken = page.pageToken
        } while (!pageToken.isNullOrEmpty())
        return samples
    }
}
