package com.otin.gym_tracker

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.metadata.Device
import androidx.health.connect.client.records.metadata.Metadata
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * Writes finished workouts to Health Connect.
 *
 * Write-only by design: the app publishes what it recorded and never reads
 * anything back, which keeps the Play health declaration narrow.
 *
 * Hand-rolled rather than via a Flutter package, for the same reason
 * [GymWearBridge] and [WorkoutBridge] are: the mature plugin (`health`) cannot
 * express exercise segments at all, and the one that can was days old at the
 * time of writing. This is a hundred lines against a stable AndroidX API.
 */
class HealthConnectBridge(
    private val appContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var activity: Activity? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    fun attach() = channel.setMethodCallHandler(this)

    fun detach() {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    fun bindActivity(activity: Activity) {
        this.activity = activity
    }

    fun unbindActivity() {
        activity = null
    }

    private val client: HealthConnectClient?
        get() = if (HealthConnectClient.getSdkStatus(appContext) ==
            HealthConnectClient.SDK_AVAILABLE
        ) {
            HealthConnectClient.getOrCreate(appContext)
        } else {
            null
        }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // "available" | "updateRequired" | "unavailable". Wear reports
            // unavailable — there is no Health Connect provider there.
            "status" -> result.success(
                // Below Android 14, Health Connect is a separate app whose
                // permissions are granted through its own intent rather than
                // the runtime permission flow used above. Rather than carry two
                // permission paths for a shrinking slice of devices, the
                // feature is simply not offered there.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    "unavailable"
                } else {
                    when (HealthConnectClient.getSdkStatus(appContext)) {
                        HealthConnectClient.SDK_AVAILABLE -> "available"
                        HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED ->
                            "updateRequired"
                        else -> "unavailable"
                    }
                }
            )

            "hasPermissions" -> {
                val hc = client
                if (hc == null) {
                    result.success(false)
                    return
                }
                scope.launch {
                    result.success(
                        runCatching {
                            hc.permissionController.getGrantedPermissions()
                                .containsAll(WRITE_PERMISSIONS)
                        }.getOrDefault(false)
                    )
                }
            }

            "requestPermissions" -> {
                val act = activity
                if (act == null || client == null) {
                    result.success(false)
                    return
                }
                // From Android 14 the health permissions are ordinary runtime
                // permissions, so the normal request flow shows Health
                // Connect's own grant screen. The androidx
                // PermissionController contract is not usable here: its
                // createIntent produces the generic androidx
                // REQUEST_PERMISSIONS action, which only resolves when launched
                // through registerForActivityResult on a ComponentActivity —
                // and FlutterActivity is a plain Activity.
                pendingPermissionResult = result
                ActivityCompat.requestPermissions(
                    act,
                    WRITE_PERMISSIONS.toTypedArray(),
                    PERMISSION_REQ_CODE,
                )
            }

            "writeWorkout" -> {
                val hc = client
                if (hc == null) {
                    result.success(false)
                    return
                }
                val startMs = (call.argument<Number>("startMs"))?.toLong()
                val endMs = (call.argument<Number>("endMs"))?.toLong()
                if (startMs == null || endMs == null) {
                    result.error("bad_args", "startMs and endMs are required", null)
                    return
                }
                val title = call.argument<String>("title")
                val clientId = call.argument<String>("clientRecordId")
                val clientVersion =
                    (call.argument<Number>("clientRecordVersion"))?.toLong() ?: 0L
                @Suppress("UNCHECKED_CAST")
                val samples = call.argument<List<Map<String, Any>>>("samples")
                    ?: emptyList()
                writeWorkout(
                    hc, startMs, endMs, title, clientId, clientVersion, samples, result,
                )
            }

            else -> result.notImplemented()
        }
    }

    private fun writeWorkout(
        hc: HealthConnectClient,
        startMs: Long,
        endMs: Long,
        title: String?,
        clientRecordId: String?,
        clientRecordVersion: Long,
        samples: List<Map<String, Any>>,
        result: MethodChannel.Result,
    ) {
        val start = Instant.ofEpochMilli(startMs)
        val end = Instant.ofEpochMilli(endMs)
        // Health Connect rejects a session that ends before it starts, and a
        // zero-length one is meaningless — a backfilled workout can have both.
        if (!end.isAfter(start)) {
            result.success(false)
            return
        }

        // clientRecordId makes republishing idempotent: Health Connect replaces
        // a record carrying the same id rather than adding a second one, so an
        // edited or re-synced workout updates in place instead of showing up
        // twice. The workout's sync id and LWW version map onto it exactly.
        // Heart rate takes a distinct id — one client id cannot address two
        // records of different types.
        fun metadataFor(suffix: String) = if (clientRecordId == null) {
            Metadata.activelyRecorded(Device(type = Device.TYPE_UNKNOWN))
        } else {
            Metadata.activelyRecorded(
                device = Device(type = Device.TYPE_UNKNOWN),
                clientRecordId = "$clientRecordId$suffix",
                clientRecordVersion = clientRecordVersion,
            )
        }
        val records = mutableListOf<androidx.health.connect.client.records.Record>(
            ExerciseSessionRecord(
                startTime = start,
                startZoneOffset = null,
                endTime = end,
                endZoneOffset = null,
                exerciseType = ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING,
                title = title,
                metadata = metadataFor(""),
            )
        )

        // Only readings inside the session window: Health Connect rejects a
        // record whose samples fall outside its own start/end, and a stray
        // reading from before the user hit start would take the whole insert
        // down with it.
        val hrSamples = samples.mapNotNull { m ->
            val t = (m["t"] as? Number)?.toLong() ?: return@mapNotNull null
            val bpm = (m["bpm"] as? Number)?.toLong() ?: return@mapNotNull null
            val at = Instant.ofEpochMilli(t)
            if (at.isBefore(start) || at.isAfter(end)) return@mapNotNull null
            HeartRateRecord.Sample(time = at, beatsPerMinute = bpm)
        }
        if (hrSamples.isNotEmpty()) {
            records += HeartRateRecord(
                startTime = hrSamples.first().time,
                startZoneOffset = null,
                endTime = hrSamples.last().time,
                endZoneOffset = null,
                samples = hrSamples,
                metadata = metadataFor(":hr"),
            )
        }

        scope.launch {
            val outcome = runCatching { hc.insertRecords(records) }
            outcome.exceptionOrNull()?.let {
                // A denied permission or a provider update lands here. The
                // workout is already saved locally; publishing is best-effort.
                Log.w(TAG, "Health Connect insert failed: ${it.message}")
            }
            result.success(outcome.isSuccess)
        }
    }

    /** Returns true if [requestCode] was ours. Called by MainActivity. */
    fun handlePermissionResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQ_CODE) return false
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        // Partial grants are possible — the user can allow exercise but refuse
        // heart rate — and publishing writes both, so anything short of all of
        // them counts as not granted.
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pending?.success(granted)
        return true
    }

    companion object {
        private const val TAG = "HealthConnectBridge"
        private const val CHANNEL = "gym_tracker/health_connect/method"
        private const val PERMISSION_REQ_CODE = 7311

        /**
         * Write-only. Every permission here must also be declared in the
         * manifest and justified in the Play health declaration, so keep the
         * set as small as the feature needs.
         */
        val WRITE_PERMISSIONS = setOf(
            HealthPermission.getWritePermission(ExerciseSessionRecord::class),
            HealthPermission.getWritePermission(HeartRateRecord::class),
        )
    }
}
