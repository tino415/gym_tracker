package com.otin.gym_tracker

import android.util.Log
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import java.io.File

/**
 * Wakes the app for sync messages that arrive while it isn't running.
 *
 * [GymWearBridge]'s `MessageClient` listener is attached from
 * `configureFlutterEngine`, so without this service an inbound message with the
 * app killed is dropped and only repaired by a later manual sync with both
 * apps open. Declared once and unflavoured — one APK serves both form factors,
 * so the phone gets background delivery of watch-completed workouts too.
 *
 * Deliberately thin: park the bytes and return. There is no Flutter engine to
 * hand them to and no Drift connection to apply them with, and every decision
 * that could live in Dart does.
 */
class SyncListenerService : WearableListenerService() {

    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != GymWearBridge.PATH) return

        // A live engine's own listener already got this one. Queueing it anyway
        // would replay it at the next start, and an authoritative routine
        // bundle deletes local routines absent from it — a stale replay is the
        // one case version-LWW does not make harmless. Losing the race (engine
        // dying right here) just drops the message, which is today's behaviour.
        if (GymWearBridge.isEngineListening) return

        try {
            SyncQueue.append(
                File(filesDir, SyncQueue.FILE_NAME),
                String(event.data, Charsets.UTF_8),
            )
            Log.d(TAG, "queued inbound ${event.path} for next app start")
        } catch (t: Throwable) {
            Log.w(TAG, "queueing inbound sync message failed: ${t.message}")
        }
    }

    companion object {
        private const val TAG = "SyncListenerService"
    }
}
