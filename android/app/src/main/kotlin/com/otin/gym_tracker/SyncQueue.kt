package com.otin.gym_tracker

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Inbound sync envelopes parked on disk while no Flutter engine is running.
 *
 * [SyncListenerService] appends here when Android wakes the app for a message
 * it would otherwise drop; [GymWearBridge]'s `drainQueue` method call hands the
 * backlog to Dart at the next `SyncService.start()`. Deliberately the *only*
 * piece of native state in the app: Kotlin can't write Drift, and handing the
 * backlog over the method channel we already own beats teaching Dart where
 * `filesDir` is.
 *
 * Storage is JSON lines — one re-serialized envelope per line, so a payload
 * that arrived with embedded newlines can't corrupt the file. Both entry points
 * take the whole file under [lock], which is the entire concurrency story:
 * service and bridge live in the same process.
 */
object SyncQueue {
    const val FILE_NAME = "wear_sync_queue.jsonl"

    /**
     * Types carrying a *full* snapshot, where only the newest is worth keeping.
     * Collapsing them is what bounds the queue semantically rather than by an
     * arbitrary cap — a watch left closed for a week parks one routine bundle,
     * not a week of them.
     */
    private val SNAPSHOT_TYPES = setOf("routine_bundle", "exercise_bundle")

    /**
     * Never queued: replaying it is meaningless, since `SyncService.start()`
     * sends a fresh one the moment the app comes up.
     */
    private const val SYNC_REQUEST = "sync_request"

    /**
     * Backstop for the types we can't collapse (`workout_completed` is a
     * distinct event each time, not a snapshot). Oldest are dropped first;
     * losing one is no worse than the drop this whole queue exists to fix.
     */
    private const val MAX_ENTRIES = 200

    private val lock = Any()

    /**
     * Park one raw wire envelope. Unparseable input and [SYNC_REQUEST] are
     * dropped rather than stored — a corrupt line would only fail again later.
     */
    fun append(file: File, envelope: String) {
        synchronized(lock) {
            val parsed = try {
                JSONObject(envelope)
            } catch (_: Throwable) {
                return
            }
            val type = parsed.optString("type")
            if (type.isEmpty() || type == SYNC_REQUEST) return

            val kept = readLines(file).filterNot {
                type in SNAPSHOT_TYPES && typeOf(it) == type
            }
            val out = (kept + parsed.toString()).takeLast(MAX_ENTRIES)
            file.writeText(out.joinToString(separator = "\n", postfix = "\n"))
        }
    }

    /**
     * Return every parked envelope in arrival order and clear the queue, in the
     * same `{type, payload}` shape a live message takes on the event channel —
     * so Dart replays them through its ordinary inbound path with no second
     * apply implementation.
     */
    fun drain(file: File): List<Map<String, Any?>> {
        synchronized(lock) {
            val lines = readLines(file)
            file.delete()
            return lines.mapNotNull { toEvent(it) }
        }
    }

    private fun readLines(file: File): List<String> =
        if (file.exists()) file.readLines().filter { it.isNotBlank() } else emptyList()

    private fun typeOf(line: String): String? = try {
        JSONObject(line).optString("type").takeIf { it.isNotEmpty() }
    } catch (_: Throwable) {
        null
    }

    private fun toEvent(line: String): Map<String, Any?>? {
        val parsed = try {
            JSONObject(line)
        } catch (_: Throwable) {
            return null
        }
        val type = parsed.optString("type")
        if (type.isEmpty()) return null
        val payload = parsed.optJSONObject("payload") ?: JSONObject()
        return mapOf("type" to type, "payload" to jsonObjectToMap(payload))
    }

    /**
     * JSON -> plain Kotlin collections. Shared with [GymWearBridge]: leaking a
     * `JSONObject` into the Flutter codec is exactly what crashed `voo_watch`
     * and why this bridge is hand-rolled, so both paths convert through here.
     */
    fun jsonObjectToMap(o: JSONObject): Map<String, Any?> {
        val m = HashMap<String, Any?>(o.length())
        for (key in o.keys()) {
            m[key] = jsonValueToNative(o.opt(key))
        }
        return m
    }

    private fun jsonArrayToList(a: JSONArray): List<Any?> {
        val list = ArrayList<Any?>(a.length())
        for (i in 0 until a.length()) {
            list.add(jsonValueToNative(a.opt(i)))
        }
        return list
    }

    private fun jsonValueToNative(v: Any?): Any? = when (v) {
        JSONObject.NULL -> null
        is JSONObject -> jsonObjectToMap(v)
        is JSONArray -> jsonArrayToList(v)
        else -> v
    }
}
