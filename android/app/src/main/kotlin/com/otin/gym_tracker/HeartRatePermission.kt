package com.otin.gym_tracker

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.health.connect.HealthPermissions
import android.os.Build
import androidx.core.content.ContextCompat

// From API 36 an app targeting 36 is never granted BODY_SENSORS: heart rate
// has a permission of its own, and Health Services checks that one.
val heartRatePermission: String =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
        HealthPermissions.READ_HEART_RATE
    } else {
        Manifest.permission.BODY_SENSORS
    }

fun Context.hasHeartRatePermission(): Boolean =
    ContextCompat.checkSelfPermission(this, heartRatePermission) ==
        PackageManager.PERMISSION_GRANTED
