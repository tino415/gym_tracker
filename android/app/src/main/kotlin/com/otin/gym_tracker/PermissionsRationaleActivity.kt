package com.otin.gym_tracker

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/**
 * Where Health Connect's permission screen sends the user when they ask why the
 * app wants their data. Health Connect requires this to exist and to lead to
 * the same privacy policy that is published in Play Console.
 *
 * Shows the summary of what is written to Health Connect, plus a button opening
 * the published policy. The summary stays on the screen rather than being
 * replaced by a WebView so the rationale still reads with no network, and so a
 * user who lands here from the permission dialog gets the specific answer
 * ("what does this app write, and does it read anything?") before the general
 * one.
 *
 * Built in code rather than with a layout resource: it is one paragraph and one
 * button, and a layout file would be more scaffolding than content.
 */
class PermissionsRationaleActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val density = resources.displayMetrics.density
        val padding = (24 * density).toInt()

        // Named `summary`, not `text`: a local called `text` would be in scope
        // inside the Button's apply block below and shadow its `text` property,
        // which fails to compile in a way that reads as a type error.
        val summary = TextView(this).apply {
            gravity = Gravity.START
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            text = getString(R.string.health_connect_rationale)
        }

        val link = Button(this).apply {
            text = getString(R.string.privacy_policy_link)
            setOnClickListener { openPrivacyPolicy() }
        }

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding, padding, padding)
            addView(summary)
            addView(
                link,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = (16 * density).toInt() },
            )
        }

        setContentView(ScrollView(this).apply { addView(column) })
    }

    /**
     * A missing browser is survivable — the toast carries the URL — but it must
     * not crash: this activity is launched by Health Connect, and an unhandled
     * ActivityNotFoundException here would look like the app failing its own
     * permission flow.
     */
    private fun openPrivacyPolicy() {
        val url = getString(R.string.privacy_policy_url)
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(
                this,
                getString(R.string.privacy_policy_unavailable),
                Toast.LENGTH_LONG,
            ).show()
        }
    }
}
