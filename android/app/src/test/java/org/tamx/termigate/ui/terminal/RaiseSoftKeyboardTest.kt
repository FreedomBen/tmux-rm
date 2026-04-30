package org.tamx.termigate.ui.terminal

import android.app.Activity
import android.app.Application
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper

/**
 * Regression tests for docs/ANDROID_DRIVE_01.md Bug 2 — tapping the terminal
 * did not raise the soft keyboard on a stock Android emulator. The fix
 * lives in [raiseSoftKeyboard] which moves focus to the target view,
 * posts a SHOW_IMPLICIT to InputMethodManager, and (when the context is
 * an Activity) also asks the WindowInsetsController to show Type.ime().
 *
 * Override the application to plain [Application] so the test does not
 * try to spin up Hilt's @HiltAndroidApp graph.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class RaiseSoftKeyboardTest {

    @Test
    fun raiseSoftKeyboard_focusesView_andShowsSoftInput() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val view = EditText(activity).apply {
            isFocusable = true
            isFocusableInTouchMode = true
        }
        activity.setContentView(view)

        raiseSoftKeyboard(view, activity)

        // showSoftInput is dispatched via View.post — drain pending main
        // looper tasks so the IMM call actually runs before we assert.
        ShadowLooper.idleMainLooper()

        assertTrue(
            "view should hold focus after raiseSoftKeyboard",
            view.hasFocus()
        )

        val imm = activity.getSystemService(InputMethodManager::class.java)
        assertNotNull(imm)
        assertTrue(
            "InputMethodManager.showSoftInput must have been called",
            Shadows.shadowOf(imm).isSoftInputVisible
        )
    }

    @Test
    fun raiseSoftKeyboard_withNonActivityContext_stillShowsSoftInput() {
        // When the helper is called with a plain Application context the
        // `(ctx as? Activity)?.let` branch is skipped — the IMM-only
        // path must still work and not crash on the missing window.
        val ctx = ApplicationProvider.getApplicationContext<Application>()

        // The IMM still needs a real window token to accept the call,
        // so attach an EditText to a Robolectric-built Activity.
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val view = EditText(activity).apply {
            isFocusable = true
            isFocusableInTouchMode = true
        }
        activity.setContentView(view)

        raiseSoftKeyboard(view, ctx)
        ShadowLooper.idleMainLooper()

        val imm = ctx.getSystemService(InputMethodManager::class.java)
        assertTrue(
            "InputMethodManager.showSoftInput must run even with a non-Activity context",
            Shadows.shadowOf(imm).isSoftInputVisible
        )
    }
}
