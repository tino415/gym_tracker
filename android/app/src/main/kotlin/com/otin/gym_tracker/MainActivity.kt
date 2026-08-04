package com.otin.gym_tracker

import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var wearBridge: GymWearBridge? = null
    private var workoutBridge: WorkoutBridge? = null
    private var healthConnectBridge: HealthConnectBridge? = null

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

        workoutBridge = WorkoutBridge(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).also {
            it.attach()
            it.bindActivity(this)
        }

        healthConnectBridge = HealthConnectBridge(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).also {
            it.attach()
            it.bindActivity(this)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        wearBridge?.detach()
        wearBridge = null
        workoutBridge?.unbindActivity()
        workoutBridge?.detach()
        workoutBridge = null
        healthConnectBridge?.unbindActivity()
        healthConnectBridge?.detach()
        healthConnectBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }


    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        workoutBridge?.handlePermissionResult(requestCode, permissions, grantResults)
        // From Android 14 the Health Connect permissions are ordinary runtime
        // permissions, so they arrive here alongside BODY_SENSORS et al.
        healthConnectBridge?.handlePermissionResult(requestCode, grantResults)
    }
}
