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
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.health.services.client.ExerciseClient
import androidx.health.services.client.ExerciseUpdateCallback
import androidx.health.services.client.HealthServices
import androidx.health.services.client.MeasureCallback
import androidx.health.services.client.MeasureClient
import androidx.health.services.client.data.Availability
import androidx.health.services.client.data.DataPointAccuracy
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.DeltaDataType
import androidx.health.services.client.data.ExerciseConfig
import androidx.health.services.client.data.ExerciseLapSummary
import androidx.health.services.client.data.ExerciseType
import androidx.health.services.client.data.ExerciseUpdate
import androidx.health.services.client.data.HeartRateAccuracy
import androidx.health.services.client.data.SampleDataPoint
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
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

    /**
     * [accuracy] is the sensor's own confidence in this reading, as one of the
     * [HR_ACCURACY_*] codes. Recorded, never acted on here — see [hasContact].
     */
    data class HeartRateSample(
        val bpm: Int,
        val timestampMs: Long,
        val accuracy: Int,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var measureClient: MeasureClient? = null
    private var measureSubscribed = false
    private var exerciseClient: ExerciseClient? = null
    private var exerciseActive = false

    // Screen-off-safe countdown. The Flutter run page owns the wall clock and
    // hands us an absolute end time; we hold a short partial wake lock so the
    // postDelayed fire stays exact even when the display sleeps, then vibrate.
    private val countdownHandler = Handler(Looper.getMainLooper())
    private var countdownRunnable: Runnable? = null
    private var wakeLock: PowerManager.WakeLock? = null

    /**
     * Primary capture path. [ExerciseClient] is the Health Services API meant
     * for a whole training session: it keeps sampling with the screen off and
     * the app backgrounded, and it puts the sensor into exercise mode, which
     * samples faster and tracks effort. [MeasureClient] — what this used to
     * use — is documented as an on-demand spot measurement for a *visible*
     * app, and in practice it delivered a reading only when the watch woke.
     */
    private val exerciseCallback = object : ExerciseUpdateCallback {
        override fun onExerciseUpdateReceived(update: ExerciseUpdate) {
            ingest(update.latestMetrics.getData(DataType.HEART_RATE_BPM))
        }

        override fun onLapSummaryReceived(lapSummary: ExerciseLapSummary) = Unit

        override fun onAvailabilityChanged(
            dataType: DataType<*, *>,
            availability: Availability,
        ) = Unit

        override fun onRegistered() = Unit

        override fun onRegistrationFailed(throwable: Throwable) {
            // Another app already owns the active exercise, or the type isn't
            // supported after all. A spot-measured HR beats none.
            Log.w(TAG, "exercise registration failed: ${throwable.message}")
            exerciseActive = false
            startMeasureFallback()
        }
    }

    private val measureCallback = object : MeasureCallback {
        override fun onAvailabilityChanged(
            dataType: DeltaDataType<*, *>,
            availability: Availability,
        ) {
            // No-op for v1: we only care whether samples arrive.
        }

        override fun onDataReceived(data: DataPointContainer) {
            ingest(data.getData(DataType.HEART_RATE_BPM))
        }
    }

    /**
     * Buffers every acceptable reading in a batch — not just the newest. A
     * batched delivery carries several points, and keeping only the last one
     * threw the rest away.
     *
     * Each point is stamped with *its own* instant rather than arrival time, so
     * a batch that lands late (or a backlog replayed after the screen wakes)
     * still records when the beat actually happened.
     */
    private fun ingest(points: List<SampleDataPoint<Double>>) {
        if (points.isEmpty()) return
        // Boot instant: Health Services timestamps are relative to boot.
        val boot = Instant.now().minusNanos(SystemClock.elapsedRealtimeNanos())
        for (p in points) {
            val bpm = p.value.toInt()
            // 0 bpm is the sensor saying "nothing here" (warm-up / off wrist),
            // never a real reading.
            if (bpm <= 0) continue
            if (!hasContact(p.accuracy)) continue
            val tMs = runCatching { p.getTimeInstant(boot).toEpochMilli() }
                .getOrDefault(System.currentTimeMillis())
            recordHeartRate(
                HeartRateSample(
                    bpm = bpm,
                    timestampMs = tMs,
                    accuracy = accuracyCode(p.accuracy),
                ),
            )
        }
    }

    /**
     * Only rejects readings the sensor says are not of a wrist at all.
     *
     * This deliberately keeps ACCURACY_LOW / UNRELIABLE. Optical PPG loses
     * confidence when the wrist is moving — which is precisely during a set —
     * so discarding those samples cut out the work intervals and left a series
     * made of rest, dragging the average down to near-resting. That is the
     * opposite of what the old gate here was trying to achieve.
     *
     * The confidence itself is not lost, though: [accuracyCode] stores it
     * alongside the reading, so a statistic can weigh it later without any
     * sample being dropped at capture.
     */
    private fun hasContact(accuracy: DataPointAccuracy?): Boolean {
        val hr = accuracy as? HeartRateAccuracy ?: return true
        return hr.sensorStatus != HeartRateAccuracy.SensorStatus.NO_CONTACT
    }

    /**
     * The sensor's confidence as a stable small int — see the `HR_ACCURACY_*`
     * constants. Codes rather than enum names because the series is the bulk of
     * a synced workout document.
     *
     * Hardware that reports no accuracy at all maps to [HR_ACCURACY_UNKNOWN],
     * which is indistinguishable from a device that says UNKNOWN. That is
     * deliberate: both mean "no confidence signal available", and a series that
     * is entirely unknown is itself the finding.
     */
    private fun accuracyCode(accuracy: DataPointAccuracy?): Int {
        val hr = accuracy as? HeartRateAccuracy ?: return HR_ACCURACY_UNKNOWN
        return when (hr.sensorStatus) {
            HeartRateAccuracy.SensorStatus.NO_CONTACT -> HR_ACCURACY_NO_CONTACT
            HeartRateAccuracy.SensorStatus.UNRELIABLE -> HR_ACCURACY_UNRELIABLE
            HeartRateAccuracy.SensorStatus.ACCURACY_LOW -> HR_ACCURACY_LOW
            HeartRateAccuracy.SensorStatus.ACCURACY_MEDIUM -> HR_ACCURACY_MEDIUM
            HeartRateAccuracy.SensorStatus.ACCURACY_HIGH -> HR_ACCURACY_HIGH
            else -> HR_ACCURACY_UNKNOWN
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
                // Health Services is a Wear API; on a phone there is nothing to
                // subscribe to, and the phone run page never asks for
                // BODY_SENSORS anyway.
                if (isWatch()) startHeartRateIfAllowed()
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
        // Deliberately *not* clearing the sample buffer: the run page finishes
        // the workout and then stops the service, and anything still undelivered
        // is a reading we'd rather hand over late than drop. The next workout
        // clears it in startHeartRateIfAllowed().
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

        // OngoingActivity is the watch-face chip — Wear-only decoration. The
        // plain notification below is what a phone shows.
        if (isWatch()) {
            val status = Status.Builder()
                .addTemplate(routineName)
                .build()
            val ongoing = OngoingActivity.Builder(applicationContext, NOTIF_ID, builder)
                .setStaticIcon(R.mipmap.ic_launcher)
                .setTouchIntent(tapPi)
                .setStatus(status)
                .build()
            ongoing.apply(applicationContext)
        }

        startForeground(NOTIF_ID, builder.build())
    }

    private fun isWatch(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_WATCH)

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
        if (exerciseActive || measureSubscribed) return
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.BODY_SENSORS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        resetHeartRate()
        startExerciseOrFallback()
    }

    /**
     * Probe first: asking a watch that can't do a strength-training exercise
     * session to start one fails asynchronously and would lose us the whole
     * workout's heart rate, so check before committing and keep the
     * [MeasureClient] path as the fallback.
     */
    private fun startExerciseOrFallback() {
        val client = try {
            HealthServices.getClient(this).exerciseClient
        } catch (t: Throwable) {
            Log.w(TAG, "no exercise client: ${t.message}")
            startMeasureFallback()
            return
        }
        val caps = try {
            client.getCapabilitiesAsync()
        } catch (t: Throwable) {
            Log.w(TAG, "getCapabilities failed: ${t.message}")
            startMeasureFallback()
            return
        }
        caps.addListener({
            val supported = runCatching {
                val c = caps.get()
                ExerciseType.STRENGTH_TRAINING in c.supportedExerciseTypes &&
                    DataType.HEART_RATE_BPM in c
                        .getExerciseTypeCapabilities(ExerciseType.STRENGTH_TRAINING)
                        .supportedDataTypes
            }.getOrDefault(false)
            if (supported) startExercise(client) else startMeasureFallback()
        }, ContextCompat.getMainExecutor(this))
    }

    private fun startExercise(client: ExerciseClient) {
        if (exerciseActive || measureSubscribed) return
        val config = ExerciseConfig.builder(ExerciseType.STRENGTH_TRAINING)
            .setDataTypes(setOf(DataType.HEART_RATE_BPM))
            // Auto-pause would stop sampling between sets — the rest periods
            // are part of the session and we want their heart rate too.
            .setIsAutoPauseAndResumeEnabled(false)
            .setIsGpsEnabled(false)
            .build()
        try {
            client.setUpdateCallback(exerciseCallback)
            exerciseClient = client
            exerciseActive = true
            val started = client.startExerciseAsync(config)
            started.addListener({
                runCatching { started.get() }.onSuccess {
                    // Which path engaged decides whether heart rate is sampled
                    // through the sets or only when the watch wakes, so say so
                    // out loud — it is the first thing to check after a run
                    // that came out reading low.
                    Log.i(TAG, "heart rate: exercise session active")
                }.onFailure {
                    Log.w(TAG, "startExercise failed: ${it.message}")
                    exerciseActive = false
                    startMeasureFallback()
                }
            }, ContextCompat.getMainExecutor(this))
        } catch (t: Throwable) {
            Log.w(TAG, "setUpdateCallback failed: ${t.message}")
            exerciseActive = false
            startMeasureFallback()
        }
    }

    private fun startMeasureFallback() {
        if (exerciseActive || measureSubscribed) return
        try {
            val client = HealthServices.getClient(this).measureClient
            client.registerMeasureCallback(DataType.HEART_RATE_BPM, measureCallback)
            measureClient = client
            measureSubscribed = true
            Log.w(TAG, "heart rate: spot-measurement fallback (screen-off gaps expected)")
        } catch (t: Throwable) {
            Log.w(TAG, "registerMeasureCallback failed: ${t.message}")
        }
    }

    private fun stopHeartRate() {
        if (exerciseActive) {
            val client = exerciseClient
            try {
                client?.endExerciseAsync()
                client?.clearUpdateCallbackAsync(exerciseCallback)
            } catch (t: Throwable) {
                Log.w(TAG, "endExercise failed: ${t.message}")
            }
            exerciseActive = false
        }
        exerciseClient = null
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

        /**
         * How often a reading is kept, in ms. Mirrors
         * `kHeartRateSampleGapMs` in `lib/watch/heart_rate_thinning.dart` —
         * keep the two in sync. Thinning happens *here*, at the producer, so a
         * reading captured while the Flutter engine was asleep is already
         * spaced correctly by the time Dart sees it.
         */
        private const val HR_MIN_GAP_MS = 5_000L

        /**
         * Sensor-confidence codes stored with every reading. Mirrors
         * `HeartRateAccuracy.SensorStatus`, and `kHrAccuracy*` in
         * `lib/watch/heart_rate_thinning.dart` — keep the three in sync.
         *
         * NO_CONTACT never reaches the buffer (see `hasContact`); its code
         * exists so the mapping stays total and the numbering keeps matching
         * the platform enum's order of confidence.
         */
        const val HR_ACCURACY_UNKNOWN = 0
        const val HR_ACCURACY_NO_CONTACT = 1
        const val HR_ACCURACY_UNRELIABLE = 2
        const val HR_ACCURACY_LOW = 3
        const val HR_ACCURACY_MEDIUM = 4
        const val HR_ACCURACY_HIGH = 5

        /** ~3 h of thinned samples. A bound, not an expected depth. */
        private const val HR_BUFFER_MAX = 2048

        private val hrLock = Any()
        private val hrBuffer = ArrayDeque<HeartRateSample>()
        private var lastBufferedMs = 0L

        /**
         * Signals that [drainHeartRate] has something. Deliberately carries no
         * payload: the buffer is the payload, and it must outlive the Flutter
         * engine. The old design published samples into a *conflating*
         * StateFlow, so everything captured while the watch screen was off —
         * i.e. every set — collapsed into a single value that the run page read
         * once it woke. A 57-minute session stored 50 readings instead of ~680,
         * one per set, all taken while the user was standing still looking at
         * the watch. That is why heart rate synced to Health Connect read
         * near-resting.
         */
        private val _heartRateAvailable = MutableSharedFlow<Unit>(
            extraBufferCapacity = 8,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )
        val heartRateAvailable: SharedFlow<Unit> = _heartRateAvailable.asSharedFlow()

        /** Buffers [sample] if it is far enough past the last one kept. */
        fun recordHeartRate(sample: HeartRateSample) {
            val buffered = synchronized(hrLock) {
                // A negative delta is an out-of-order reading; the samples table
                // is keyed on the timestamp and upserts, so letting one through
                // would overwrite a good reading with a stale one.
                if (sample.timestampMs - lastBufferedMs < HR_MIN_GAP_MS) {
                    return@synchronized false
                }
                lastBufferedMs = sample.timestampMs
                hrBuffer.addLast(sample)
                while (hrBuffer.size > HR_BUFFER_MAX) hrBuffer.removeFirst()
                true
            }
            if (buffered) _heartRateAvailable.tryEmit(Unit)
        }

        /** Removes and returns everything buffered, oldest first. */
        fun drainHeartRate(): List<HeartRateSample> = synchronized(hrLock) {
            if (hrBuffer.isEmpty()) {
                emptyList()
            } else {
                ArrayList(hrBuffer).also { hrBuffer.clear() }
            }
        }

        /** Puts a batch back after a failed delivery (no event sink attached). */
        fun returnHeartRate(samples: List<HeartRateSample>) = synchronized(hrLock) {
            for (s in samples.asReversed()) hrBuffer.addFirst(s)
            while (hrBuffer.size > HR_BUFFER_MAX) hrBuffer.removeFirst()
        }

        private fun resetHeartRate() = synchronized(hrLock) {
            hrBuffer.clear()
            lastBufferedMs = 0L
        }

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
