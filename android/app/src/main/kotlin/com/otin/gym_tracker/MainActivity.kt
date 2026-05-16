package com.otin.gym_tracker

import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var wearBridge: GymWearBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "gym_tracker/platform",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isWatch" -> {
                    val pm = applicationContext.packageManager
                    result.success(pm.hasSystemFeature(PackageManager.FEATURE_WATCH))
                }
                else -> result.notImplemented()
            }
        }

        wearBridge = GymWearBridge(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).also { it.attach() }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        wearBridge?.detach()
        wearBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
