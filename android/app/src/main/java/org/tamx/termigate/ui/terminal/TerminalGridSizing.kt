package org.tamx.termigate.ui.terminal

import kotlin.math.max

/**
 * Derive cols/rows that fit the given viewport pixel area at the
 * given cell pixel dimensions. Floors partial cells so the grid never
 * extends past the viewport edge, and clamps to [minCols]/[minRows]
 * when the viewport is too small or the cell metrics have not yet
 * been measured.
 *
 * Bug 4 fix in docs/ANDROID_DRIVE_01.md — earlier code hardcoded an 80×24
 * grid and the Compose layer sized the Android view to exactly that
 * grid in pixels, leaving most of the screen empty.
 */
internal fun fitGridToViewport(
    viewportWidthPx: Int,
    viewportHeightPx: Int,
    cellWidthPx: Int,
    cellHeightPx: Int,
    minCols: Int,
    minRows: Int
): Pair<Int, Int> {
    if (cellWidthPx <= 0 || cellHeightPx <= 0) {
        return minCols to minRows
    }
    val cols = max(minCols, viewportWidthPx / cellWidthPx)
    val rows = max(minRows, viewportHeightPx / cellHeightPx)
    return cols to rows
}
