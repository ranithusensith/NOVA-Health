package com.example.nova_health

import android.content.Intent
import android.net.Uri
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.request.AggregateRequest
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
                if (call.method !in setOf("readHeartRate", "readSteps", "readAsleep")) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val arguments = call.arguments as? Map<*, *>
                val start = arguments?.get("start") as? Number
                val end = arguments?.get("end") as? Number
                if (start == null || end == null || start.toLong() >= end.toLong()) {
                    result.error("INVALID_RANGE", "Invalid health query range.", null)
                    return@setMethodCallHandler
                }
                lifecycleScope.launch {
                    try {
                        val from = start.toLong()
                        val to = end.toLong()
                        result.success(when (call.method) {
                            "readHeartRate" -> readHeartRate(from, to)
                            "readSteps" -> readSteps(from, to)
                            else -> readAsleep(from, to)
                        })
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: SecurityException) {
                        if (call.method == "readHeartRate") {
                            result.error("HEART_RATE_UNAVAILABLE", "Could not read heart rate.", null)
                        } else {
                            result.error("HEALTH_READ_DENIED", "Health Connect read access was denied.", null)
                        }
                    } catch (_: Exception) {
                        // The upstream plugin logs the raw exception from this query.
                        if (call.method == "readHeartRate") {
                            result.error("HEART_RATE_UNAVAILABLE", "Could not read heart rate.", null)
                        } else {
                            result.error("HEALTH_READ_UNAVAILABLE", "Could not read Health Connect.", null)
                        }
                    }
                }
            }
    }

    private suspend fun readSteps(start: Long, end: Long): Long? {
        val client = HealthConnectClient.getOrCreate(this)
        val range = TimeRangeFilter.between(Instant.ofEpochMilli(start), Instant.ofEpochMilli(end))
        return client.aggregate(AggregateRequest(
            metrics = setOf(StepsRecord.COUNT_TOTAL),
            timeRangeFilter = range,
        ))[StepsRecord.COUNT_TOTAL]
    }

    private suspend fun readAsleep(start: Long, end: Long): List<Map<String, Long>> {
        val client = HealthConnectClient.getOrCreate(this)
        val range = TimeRangeFilter.between(Instant.ofEpochMilli(start), Instant.ofEpochMilli(end))
        val asleep = setOf(
            SleepSessionRecord.STAGE_TYPE_SLEEPING, SleepSessionRecord.STAGE_TYPE_LIGHT,
            SleepSessionRecord.STAGE_TYPE_DEEP, SleepSessionRecord.STAGE_TYPE_REM,
        )
        val intervals = mutableListOf<Map<String, Long>>()
        var pageToken: String? = null
        do {
            val page = client.readRecords(ReadRecordsRequest(
                recordType = SleepSessionRecord::class,
                timeRangeFilter = range,
                pageToken = pageToken,
            ))
            for (record in page.records) {
                for (stage in record.stages) {
                    if (stage.stage in asleep) {
                        intervals.add(mapOf(
                            "start" to stage.startTime.toEpochMilli(),
                            "end" to stage.endTime.toEpochMilli(),
                        ))
                    }
                }
            }
            if (intervals.size > 20_000) throw IllegalStateException("Too many sleep intervals")
            pageToken = page.pageToken
        } while (!pageToken.isNullOrEmpty())
        return intervals
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
