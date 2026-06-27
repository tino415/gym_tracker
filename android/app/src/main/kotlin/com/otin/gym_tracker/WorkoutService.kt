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
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
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
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
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

    // Screen-off-safe countdown. The Flutter run page owns the wall clock and
    // hands us an absolute end time; we hold a short partial wake lock so the
    // postDelayed fire stays exact even when the display sleeps, then vibrate.
    private val countdownHandler = Handler(Looper.getMainLooper())
    private var countdownRunnable: Runnable? = null
    private var wakeLock: PowerManager.WakeLock? = null

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
            ACTION_SET_TIMER -> {
                // A timer action must only ever land on the live foreground
                // workout service. If we got here as a freshly-created instance
                // (e.g. a clearTimer raced a stop, or the OS reclaimed us), stop
                // immediately rather than linger as an orphaned background
                // service holding a wake lock.
                if (!_running.value) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                val kind = intent.getStringExtra(EXTRA_TIMER_KIND) ?: KIND_REST
                val endMs = intent.getLongExtra(EXTRA_TIMER_END_MS, 0L)
                scheduleCountdown(kind, endMs)
            }
            ACTION_CLEAR_TIMER -> {
                cancelCountdown()
                if (!_running.value) stopSelf()
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
        cancelCountdown()
        stopHeartRate()
        _running.value = false
        _heartRate.value = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // --- Countdown (rest / time-set) ---------------------------------------

    private fun scheduleCountdown(kind: String, endTimeMs: Long) {
        cancelCountdown()
        val remaining = endTimeMs - System.currentTimeMillis()
        // Keep the CPU awake for the countdown so the postDelayed fire is exact
        // with the screen off. The +5s timeout is a hard cap so the lock can
        // never leak even if the fire is somehow dropped.
        acquireWakeLock(remaining + 5_000L)
        val r = Runnable { fireCountdown(kind) }
        countdownRunnable = r
        countdownHandler.postDelayed(r, remaining.coerceAtLeast(0L))
    }

    private fun fireCountdown(kind: String) {
        vibrateFor(kind)
        _timerDone.tryEmit(TimerDone(kind))
        countdownRunnable = null
        releaseWakeLock()
    }

    private fun cancelCountdown() {
        countdownRunnable?.let { countdownHandler.removeCallbacks(it) }
        countdownRunnable = null
        releaseWakeLock()
    }

    private fun acquireWakeLock(timeoutMs: Long) {
        releaseWakeLock()
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gym_tracker:countdown")
            .also { it.acquire(timeoutMs.coerceAtLeast(0L)) }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    @Suppress("DEPRECATION")
    private fun vibrateFor(kind: String) {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vm = getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vm.defaultVibrator
        } else {
            getSystemService(VIBRATOR_SERVICE) as Vibrator
        }
        // Rest over = a stronger double buzz; a time-set hold ending = single.
        val effect = if (kind == KIND_REST) {
            VibrationEffect.createWaveform(longArrayOf(0, 400, 200, 400), -1)
        } else {
            VibrationEffect.createOneShot(400, VibrationEffect.DEFAULT_AMPLITUDE)
        }
        vibrator.vibrate(effect)
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

    data class TimerDone(val kind: String)

    companion object {
        private const val TAG = "WorkoutService"
        private const val CHANNEL_ID = "workout_active"
        private const val NOTIF_ID = 4711
        const val ACTION_START = "com.otin.gym_tracker.action.WORKOUT_START"
        const val ACTION_STOP = "com.otin.gym_tracker.action.WORKOUT_STOP"
        const val ACTION_SET_TIMER = "com.otin.gym_tracker.action.SET_TIMER"
        const val ACTION_CLEAR_TIMER = "com.otin.gym_tracker.action.CLEAR_TIMER"
        const val EXTRA_ROUTINE_NAME = "routineName"
        const val EXTRA_TIMER_KIND = "timerKind"
        const val EXTRA_TIMER_END_MS = "timerEndMs"
        const val KIND_REST = "rest"
        const val KIND_TIME = "time"

        private val _heartRate = MutableStateFlow<HeartRateSample?>(null)
        val heartRate: StateFlow<HeartRateSample?> = _heartRate.asStateFlow()
        private val _running = MutableStateFlow(false)
        val running: StateFlow<Boolean> = _running.asStateFlow()
        // Each fire is a distinct event (no replay/dedup), so a SharedFlow, not
        // a StateFlow — re-arming the same kind must still notify.
        private val _timerDone = MutableSharedFlow<TimerDone>(extraBufferCapacity = 4)
        val timerDone: SharedFlow<TimerDone> = _timerDone.asSharedFlow()

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

        // Schedules a one-shot vibration at [endTimeMs] (epoch millis). Only
        // called while the workout service is already foreground, so a plain
        // startService is allowed.
        fun setTimer(context: Context, kind: String, endTimeMs: Long) {
            val intent = Intent(context, WorkoutService::class.java).apply {
                action = ACTION_SET_TIMER
                putExtra(EXTRA_TIMER_KIND, kind)
                putExtra(EXTRA_TIMER_END_MS, endTimeMs)
            }
            context.startService(intent)
        }

        fun clearTimer(context: Context) {
            val intent = Intent(context, WorkoutService::class.java).apply {
                action = ACTION_CLEAR_TIMER
            }
            context.startService(intent)
        }
    }
}
