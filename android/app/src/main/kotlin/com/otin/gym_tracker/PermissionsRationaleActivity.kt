package com.otin.gym_tracker

import android.app.Activity
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.widget.ScrollView
import android.widget.TextView

/**
 * Where Health Connect's permission screen sends the user when they ask why the
 * app wants their data. Health Connect requires this to exist and to show the
 * same privacy policy that is published in Play Console.
 *
 * TODO: we have no published policy yet — see the "Privacy policy URL and Play
 * data-safety form" task. Until it exists this shows an in-app explanation,
 * which is honest but will not satisfy the Health Connect review. Point it at
 * the real policy before release.
 *
 * Built in code rather than with a layout resource: it is a single paragraph,
 * and a layout file would be more scaffolding than content.
 */
class PermissionsRationaleActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val padding = (24 * resources.displayMetrics.density).toInt()
        val text = TextView(this).apply {
            setPadding(padding, padding, padding, padding)
            gravity = Gravity.START
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            text = getString(R.string.health_connect_rationale)
        }
        setContentView(ScrollView(this).apply { addView(text) })
    }
}
