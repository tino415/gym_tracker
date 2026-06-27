package com.otin.gym_tracker

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * Dart bridge for the foreground workout service. Mirrors GymWearBridge's
 * shape: one MethodChannel for commands + one EventChannel for streaming
 * heart-rate events to Flutter.
 */
class WorkoutBridge(
    context: Context,
    binaryMessenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val appContext = context.applicationContext
    private val methodChannel = MethodChannel(binaryMessenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(binaryMessenger, EVENT_CHANNEL)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var collectJob: Job? = null
    private var timerJob: Job? = null

    private var activity: Activity? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    fun attach() {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    fun detach() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        collectJob?.cancel()
        collectJob = null
        timerJob?.cancel()
        timerJob = null
        scope.cancel()
    }

    fun bindActivity(activity: Activity) {
        this.activity = activity
    }

    fun unbindActivity() {
        activity = null
        pendingPermissionResult = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val name = call.argument<String>("routineName") ?: "Workout"
                WorkoutService.start(appContext, name)
                result.success(null)
            }
            "stop" -> {
                WorkoutService.stop(appContext)
                result.success(null)
            }
            "setTimer" -> {
                val kind = call.argument<String>("kind") ?: WorkoutService.KIND_REST
                val endMs = (call.argument<Number>("endTimeMs"))?.toLong()
                if (endMs == null) {
                    result.error("bad_args", "endTimeMs required", null)
                } else {
                    WorkoutService.setTimer(appContext, kind, endMs)
                    result.success(null)
                }
            }
            "clearTimer" -> {
                WorkoutService.clearTimer(appContext)
                result.success(null)
            }
            "hasBodySensorsPermission" -> {
                result.success(hasBodySensors())
            }
            "requestPermissions" -> {
                val act = activity
                if (act == null) {
                    result.error("no_activity", "No bound activity", null)
                    return
                }
                val perms = mutableListOf(Manifest.permission.BODY_SENSORS)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    perms += Manifest.permission.POST_NOTIFICATIONS
                }
                val missing = perms.filter {
                    ContextCompat.checkSelfPermission(appContext, it) !=
                        PackageManager.PERMISSION_GRANTED
                }
                if (missing.isEmpty()) {
                    result.success(true)
                    return
                }
                pendingPermissionResult = result
                ActivityCompat.requestPermissions(
                    act,
                    missing.toTypedArray(),
                    PERMISSION_REQ_CODE,
                )
            }
            else -> result.notImplemented()
        }
    }

    fun handlePermissionResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQ_CODE) return false
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pending?.success(granted)
        return true
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        collectJob?.cancel()
        collectJob = scope.launch {
            WorkoutService.heartRate.collect { sample ->
                if (sample == null) return@collect
                val payload = mapOf(
                    "bpm" to sample.bpm,
                    "timestampMs" to sample.timestampMs,
                )
                mainHandler.post {
                    sink?.success(
                        mapOf(
                            "type" to "heartRate",
                            "payload" to payload,
                        ),
                    )
                }
            }
        }
        timerJob?.cancel()
        timerJob = scope.launch {
            WorkoutService.timerDone.collect { event ->
                mainHandler.post {
                    sink?.success(
                        mapOf(
                            "type" to "timerDone",
                            "payload" to mapOf("kind" to event.kind),
                        ),
                    )
                }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        collectJob?.cancel()
        collectJob = null
        timerJob?.cancel()
        timerJob = null
    }

    private fun hasBodySensors(): Boolean = ContextCompat.checkSelfPermission(
        appContext,
        Manifest.permission.BODY_SENSORS,
    ) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val METHOD_CHANNEL = "gym_tracker/workout/method"
        private const val EVENT_CHANNEL = "gym_tracker/workout/events"
        const val PERMISSION_REQ_CODE = 8421
    }
}
