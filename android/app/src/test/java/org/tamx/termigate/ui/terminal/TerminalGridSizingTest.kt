package org.tamx.termigate.ui.terminal

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Regression tests for ANDROID_DRIVE_01.md Bug 4 — the terminal was
 * connecting with a hardcoded 80×24 grid and the Compose viewport
 * sized the Android view to exactly `cols * cellWidthPx × rows *
 * cellHeightPx`. On most phones this leaves a small terminal in a
 * corner of the screen with the rest of the viewport empty.
 *
 * The fix derives cols/rows from the available viewport pixels and
 * the measured cell pixel dimensions. [fitGridToViewport] is the pure
 * math at the centre of that fix; it is unit-tested here so the
 * contract stays nailed down even as the Compose wiring around it
 * evolves.
 */
class TerminalGridSizingTest {

    @Test
    fun fits_cols_and_rows_to_viewport_pixels() {
        // 1080x2400 viewport with 12px-wide / 48px-tall cells →
        // 90 cols (1080/12) × 50 rows (2400/48).
        val (cols, rows) = fitGridToViewport(
            viewportWidthPx = 1080,
            viewportHeightPx = 2400,
            cellWidthPx = 12,
            cellHeightPx = 48,
            minCols = 2,
            minRows = 2
        )
        assertEquals(90, cols)
        assertEquals(50, rows)
    }

    @Test
    fun truncates_partial_cells_rather_than_rounding_up() {
        // 1000x500 viewport with 12x16 cells → floor(83.33) = 83 cols,
        // floor(31.25) = 31 rows. Rounding up would render a partial
        // cell past the viewport edge, which is what Bug 4 was about
        // in the inverse direction (grid too small instead of too big).
        val (cols, rows) = fitGridToViewport(
            viewportWidthPx = 1000,
            viewportHeightPx = 500,
            cellWidthPx = 12,
            cellHeightPx = 16,
            minCols = 2,
            minRows = 2
        )
        assertEquals(83, cols)
        assertEquals(31, rows)
    }

    @Test
    fun clamps_to_min_when_viewport_smaller_than_min_grid() {
        // A 10x10 viewport with 50x50 cells would yield 0 cols/rows
        // under floor division. Clamp to the caller's minimum so we
        // never ask the server for a zero-cell pane.
        val (cols, rows) = fitGridToViewport(
            viewportWidthPx = 10,
            viewportHeightPx = 10,
            cellWidthPx = 50,
            cellHeightPx = 50,
            minCols = 2,
            minRows = 2
        )
        assertEquals(2, cols)
        assertEquals(2, rows)
    }

    @Test
    fun clamps_to_min_when_cell_dims_are_zero_or_negative() {
        // Defensive: cellWidthPx/cellHeightPx briefly read 0 before
        // the TerminalView's first layout pass produces real cell
        // metrics. We must not divide by zero or return a 0-cell grid.
        val (cols, rows) = fitGridToViewport(
            viewportWidthPx = 1080,
            viewportHeightPx = 2400,
            cellWidthPx = 0,
            cellHeightPx = -1,
            minCols = 2,
            minRows = 2
        )
        assertEquals(2, cols)
        assertEquals(2, rows)
    }
}
