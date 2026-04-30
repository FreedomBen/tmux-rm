package org.tamx.termigate.ui.sessions

import android.app.Application
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.tamx.termigate.data.model.Pane
import org.tamx.termigate.data.model.Session

/**
 * Compose UI regression tests for ANDROID_DRIVE_01.md Bug 10. Tapping
 * a single-pane session row must navigate straight to that pane;
 * multi-pane rows must keep their original toggle-expand behavior so
 * the user can choose a pane.
 *
 * Override the test application to plain [Application] so Robolectric
 * does not try to wire up Hilt's @HiltAndroidApp graph.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class SessionCardTapTest {

    @get:Rule
    val composeTestRule = createComposeRule()

    private fun pane(idx: Int): Pane = Pane(
        sessionName = "alpha",
        windowIndex = 0,
        index = idx,
        width = 80,
        height = 24,
        command = "bash",
        paneId = "%$idx"
    )

    @Test
    fun tapping_a_single_pane_session_navigates_directly() {
        var clickedTarget: String? = null
        val session = Session(
            name = "alpha",
            windows = 1,
            attached = false,
            panes = listOf(pane(0))
        )

        composeTestRule.setContent {
            SessionCard(
                session = session,
                onPaneClicked = { clickedTarget = it },
                onRename = {},
                onDelete = {},
                onCreateWindow = {},
                onSplitPane = { _, _ -> },
                onDeletePane = {}
            )
        }

        composeTestRule.onNodeWithText("alpha").performClick()

        assertEquals(
            "single-pane session row tap should navigate to the pane",
            "alpha:0.0",
            clickedTarget
        )
    }

    @Test
    fun tapping_a_multi_pane_session_does_not_navigate() {
        var clickedTarget: String? = null
        val session = Session(
            name = "alpha",
            windows = 1,
            attached = false,
            panes = listOf(pane(0), pane(1))
        )

        composeTestRule.setContent {
            SessionCard(
                session = session,
                onPaneClicked = { clickedTarget = it },
                onRename = {},
                onDelete = {},
                onCreateWindow = {},
                onSplitPane = { _, _ -> },
                onDeletePane = {}
            )
        }

        composeTestRule.onNodeWithText("alpha").performClick()

        assertNull(
            "multi-pane session row tap should expand, not navigate",
            clickedTarget
        )
    }
}
