package com.otin.gym_tracker

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.health.services.client.HealthServices
import androidx.health.services.client.MeasureCallback
import androidx.health.services.client.MeasureClient
import androidx.health.services.client.data.Availability
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.DeltaDataType
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Foreground service that represents an active workout on Wear OS. It surfaces
 * an OngoingActivity (the small chip the system shows on the watch face) and
 * subscribes to Health Services for heart-rate samples while running.
 *
 * Heart-rate samples and run state are exposed via [heartRate] / [running] —
 * the Flutter bridge collects from those flows; no AIDL/IPC needed since the
 * service lives in the same process as the Flutter activity.
 */
class WorkoutService : Service() {

    data class HeartRateSample(val bpm: Int, val timestampMs: Long)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var measureClient: MeasureClient? = null
    private var measureSubscribed = false

    private val measureCallback = object : MeasureCallback {
        override fun onAvailabilityChanged(
            dataType: DeltaDataType<*, *>,
            availability: Availability,
        ) {
            // No-op for v1: we only care whether samples arrive.
        }

        override fun onDataReceived(data: DataPointContainer) {
            val samples = data.getData(DataType.HEART_RATE_BPM)
            // Health Services emits 0 during sensor warm-up or off-body — drop
            // those so the watch / aggregates never see a phantom 0 BPM.
            val latest = samples.lastOrNull { it.value > 0.0 } ?: return
            _heartRate.value = HeartRateSample(
                bpm = latest.value.toInt(),
                timestampMs = System.currentTimeMillis(),
            )
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val routineName = intent.getStringExtra(EXTRA_ROUTINE_NAME)
                    ?: "Workout"
                startInForeground(routineName)
                startHeartRateIfAllowed()
                _running.value = true
            }
            ACTION_STOP -> {
                shutdown()
            }
            else -> {
                // Unknown / null intent: nothing to do, don't keep ourselves
                // alive without an ongoing notification.
                shutdown()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        shutdown()
        scope.cancel()
        super.onDestroy()
    }

    private fun shutdown() {
        stopHeartRate()
        _running.value = false
        _heartRate.value = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startInForeground(routineName: String) {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val tapPi = PendingIntent.getActivity(
            this,
            0,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Workout")
            .setContentText(routineName)
            .setContentIntent(tapPi)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_WORKOUT)

        val status = Status.Builder()
            .addTemplate(routineName)
            .build()
        val ongoing = OngoingActivity.Builder(applicationContext, NOTIF_ID, builder)
            .setStaticIcon(R.mipmap.ic_launcher)
            .setTouchIntent(tapPi)
            .setStatus(status)
            .build()
        ongoing.apply(applicationContext)

        startForeground(NOTIF_ID, builder.build())
    }

    private fun ensureChannel() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Active workout",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows while a workout is in progress."
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun startHeartRateIfAllowed() {
        if (measureSubscribed) return
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.BODY_SENSORS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        try {
            val client = HealthServices.getClient(this).measureClient
            client.registerMeasureCallback(DataType.HEART_RATE_BPM, measureCallback)
            measureClient = client
            measureSubscribed = true
        } catch (t: Throwable) {
            Log.w(TAG, "registerMeasureCallback failed: ${t.message}")
        }
    }

    private fun stopHeartRate() {
        val client = measureClient ?: return
        if (measureSubscribed) {
            try {
                client.unregisterMeasureCallbackAsync(
                    DataType.HEART_RATE_BPM,
                    measureCallback,
                )
            } catch (t: Throwable) {
                Log.w(TAG, "unregisterMeasureCallback failed: ${t.message}")
            }
            measureSubscribed = false
        }
        measureClient = null
    }

    companion object {
        private const val TAG = "WorkoutService"
        private const val CHANNEL_ID = "workout_active"
        private const val NOTIF_ID = 4711
        const val ACTION_START = "com.otin.gym_tracker.action.WORKOUT_START"
        const val ACTION_STOP = "com.otin.gym_tracker.action.WORKOUT_STOP"
        const val EXTRA_ROUTINE_NAME = "routineName"

        private val _heartRate = MutableStateFlow<HeartRateSample?>(null)
        val heartRate: StateFlow<HeartRateSample?> = _heartRate.asStateFlow()
        private val _running = MutableStateFlow(false)
        val running: StateFlow<Boolean> = _running.asStateFlow()

        fun start(context: Context, routineName: String) {
            val intent = Intent(context, WorkoutService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ROUTINE_NAME, routineName)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, WorkoutService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }
}
