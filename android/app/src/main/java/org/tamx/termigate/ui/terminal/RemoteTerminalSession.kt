package org.tamx.termigate.ui.terminal

import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient

/**
 * A TerminalSession subclass for remote terminal connections.
 * Instead of spawning a local shell process, it bridges the Termux
 * TerminalEmulator with a remote server via WebSocket.
 *
 * - Server output is fed via [feedInput] / [resetAndFeedInput]
 * - Keyboard input (from TerminalView) is captured via [write] override
 *   and forwarded to [onWrite] callback for sending to the server
 *
 * Sizing model: the emulator's cols/rows mirror the **server-side tmux pane**,
 * not the Android view's pixel size. The view's [updateSize] callback only
 * tells us the **cell pixel** dimensions; we cache those and notify
 * [onCellDimensionsChanged] but never reshape the emulator from view dims.
 * Emulator cols/rows change only via [resizeEmulator] (driven by server
 * `resized` events) or the initial join dims supplied to the constructor.
 */
class RemoteTerminalSession(
    client: TerminalSessionClient,
    private val initialCols: Int,
    private val initialRows: Int,
    private val onWrite: (ByteArray) -> Unit,
    private val onCellDimensionsChanged: (cellWidthPx: Int, cellHeightPx: Int) -> Unit
) : TerminalSession("/bin/true", "/", emptyArray(), emptyArray(), null, client) {

    /** History data to feed after emulator is initialized by TerminalView. */
    var pendingHistory: ByteArray? = null

    var cellWidthPx: Int = 0
        private set
    var cellHeightPx: Int = 0
        private set

    override fun initializeEmulator(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        cellWidthPx = cellWidthPixels
        cellHeightPx = cellHeightPixels
        mEmulator = TerminalEmulator(this, columns, rows, cellWidthPixels, cellHeightPixels, 10000, mClient)
        if (cellWidthPixels > 0 && cellHeightPixels > 0) {
            onCellDimensionsChanged(cellWidthPixels, cellHeightPixels)
        }
    }

    override fun updateSize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        if (mEmulator == null) {
            // First measure: create the emulator at the tmux pane's known dims,
            // not the view's measured cols/rows. The view's cols/rows are
            // discarded; we only adopt its cell pixel dims.
            initializeEmulator(initialCols, initialRows, cellWidthPixels, cellHeightPixels)
        } else if (cellWidthPixels != cellWidthPx || cellHeightPixels != cellHeightPx) {
            // Subsequent measures only update cached cell pixel dims (e.g. on
            // font-size change). Do not resize the emulator from view dims.
            cellWidthPx = cellWidthPixels
            cellHeightPx = cellHeightPixels
            if (cellWidthPixels > 0 && cellHeightPixels > 0) {
                onCellDimensionsChanged(cellWidthPixels, cellHeightPixels)
            }
        }
    }

    override fun write(data: ByteArray, offset: Int, count: Int) {
        onWrite(data.sliceArray(offset until offset + count))
    }

    /** Feed terminal output data from the server into the emulator. */
    fun feedInput(data: ByteArray) {
        mEmulator?.append(data, data.size)
    }

    /** Reset emulator and feed full buffer (used on reconnect). */
    fun resetAndFeedInput(data: ByteArray) {
        mEmulator?.reset()
        mEmulator?.append(data, data.size)
    }

    fun resizeEmulator(cols: Int, rows: Int) {
        mEmulator?.resize(cols, rows, cellWidthPx, cellHeightPx)
    }
}
