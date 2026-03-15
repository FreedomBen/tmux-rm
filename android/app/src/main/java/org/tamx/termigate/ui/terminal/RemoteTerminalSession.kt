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
 */
class RemoteTerminalSession(
    client: TerminalSessionClient,
    private val onWrite: (ByteArray) -> Unit
) : TerminalSession("/bin/true", "/", emptyArray(), emptyArray(), null, client) {

    /** History data to feed after emulator is initialized by TerminalView. */
    var pendingHistory: ByteArray? = null

    override fun initializeEmulator(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        mEmulator = TerminalEmulator(this, columns, rows, cellWidthPixels, cellHeightPixels, 10000, mClient)
    }

    override fun updateSize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        if (mEmulator == null) {
            initializeEmulator(columns, rows, cellWidthPixels, cellHeightPixels)
        } else {
            mEmulator.resize(columns, rows, cellWidthPixels, cellHeightPixels)
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
        mEmulator?.resize(cols, rows, 0, 0)
    }
}
