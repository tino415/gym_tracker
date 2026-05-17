package com.otin.gym_tracker

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.CapabilityInfo
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import org.json.JSONArray
import org.json.JSONObject

class GymWearBridge(
    context: Context,
    binaryMessenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    MessageClient.OnMessageReceivedListener,
    CapabilityClient.OnCapabilityChangedListener {

    private val appContext = context.applicationContext
    private val methodChannel = MethodChannel(binaryMessenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(binaryMessenger, EVENT_CHANNEL)
    private val messageClient: MessageClient = Wearable.getMessageClient(appContext)
    private val capabilityClient: CapabilityClient =
        Wearable.getCapabilityClient(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    fun attach() {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        messageClient.addListener(this)
        capabilityClient.addListener(this, CAPABILITY)
    }

    fun detach() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        messageClient.removeListener(this)
        capabilityClient.removeListener(this)
        scope.cancel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "send" -> {
                val type = call.argument<String>("type")
                @Suppress("UNCHECKED_CAST")
                val payload = call.argument<Map<String, Any?>>("payload")
                if (type == null || payload == null) {
                    result.error("invalid_args", "send requires type + payload", null)
                    return
                }
                send(type, payload, result)
            }
            "refreshReachability" -> {
                emitReachability()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun send(
        type: String,
        payload: Map<String, Any?>,
        result: MethodChannel.Result,
    ) {
        val envelope = JSONObject().apply {
            put("type", type)
            put("payload", JSONObject(payload))
        }
        val bytes = envelope.toString().toByteArray(Charsets.UTF_8)
        scope.launch {
            try {
                val nodes = capabilityClient
                    .getCapability(CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                    .await()
                    .nodes
                for (node in nodes) {
                    messageClient.sendMessage(node.id, PATH, bytes).await()
                }
                result.success(null)
            } catch (t: Throwable) {
                Log.w(TAG, "send($type) failed: ${t.message}")
                result.error("send_failed", t.message ?: "send failed", null)
            }
        }
    }

    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != PATH) return
        val parsed = try {
            JSONObject(String(event.data, Charsets.UTF_8))
        } catch (_: Throwable) {
            return
        }
        val type = parsed.optString("type")
        val payload = parsed.optJSONObject("payload") ?: JSONObject()
        val map = mapOf("type" to type, "payload" to jsonObjectToMap(payload))
        mainHandler.post {
            sink?.success(map)
        }
    }

    override fun onCapabilityChanged(info: CapabilityInfo) {
        emitReachability()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        emitReachability()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emitReachability() {
        scope.launch {
            val state = try {
                val info = capabilityClient
                    .getCapability(CAPABILITY, CapabilityClient.FILTER_ALL)
                    .await()
                when {
                    info.nodes.isEmpty() -> "notPaired"
                    info.nodes.none { it.isNearby } -> "pairedButNotReachable"
                    else -> "reachable"
                }
            } catch (_: Throwable) {
                "notPaired"
            }
            mainHandler.post {
                sink?.success(mapOf("type" to "_reachability", "payload" to mapOf("state" to state)))
            }
        }
    }

    private fun jsonObjectToMap(o: JSONObject): Map<String, Any?> {
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

    companion object {
        private const val TAG = "GymWearBridge"
        private const val METHOD_CHANNEL = "gym_tracker/wear/method"
        private const val EVENT_CHANNEL = "gym_tracker/wear/events"
        private const val PATH = "/gym_tracker/sync"
        private const val CAPABILITY = "gym_tracker_sync"
    }
}
