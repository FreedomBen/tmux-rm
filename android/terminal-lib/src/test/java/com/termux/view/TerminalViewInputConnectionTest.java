package com.termux.view;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;

import android.content.Context;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.ExtractedTextRequest;
import android.view.inputmethod.InputConnection;

import androidx.test.core.app.ApplicationProvider;

import com.termux.terminal.TerminalSession;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

/**
 * Regression tests for docs/ANDROID_DRIVE_01.md Bug 3 — the soft keyboard
 * was rendering a duplicate of the terminal cells at the bottom of the
 * screen because the IME's extracted-text mirror was active.
 *
 * The fix has two layers and both are exercised here:
 *   1. EditorInfo.imeOptions advertises IME_FLAG_NO_EXTRACT_UI so the
 *      IME never opens its extract-text overlay in the first place.
 *   2. InputConnection.getExtractedText() returns null so any IME that
 *      asks for the mirror anyway gets nothing back.
 */
@RunWith(RobolectricTestRunner.class)
public class TerminalViewInputConnectionTest {

    private TerminalView newView() {
        Context ctx = ApplicationProvider.getApplicationContext();
        TerminalView view = new TerminalView(ctx, null);
        view.setTerminalViewClient(new StubClient());
        return view;
    }

    /**
     * Minimal {@link TerminalViewClient} that satisfies the interface so
     * {@link TerminalView#onCreateInputConnection(EditorInfo)} can run
     * without NPEing on a null client. We claim the view is selected so
     * the IME-flag setup path is exercised — that path is what Bug 3
     * was about.
     */
    private static final class StubClient implements TerminalViewClient {
        @Override public float onScale(float scale) { return scale; }
        @Override public void onSingleTapUp(MotionEvent e) {}
        @Override public boolean shouldBackButtonBeMappedToEscape() { return false; }
        @Override public boolean shouldEnforceCharBasedInput() { return false; }
        @Override public boolean shouldUseCtrlSpaceWorkaround() { return false; }
        @Override public boolean isTerminalViewSelected() { return true; }
        @Override public void copyModeChanged(boolean copyMode) {}
        @Override public boolean onKeyDown(int keyCode, KeyEvent e, TerminalSession session) { return false; }
        @Override public boolean onKeyUp(int keyCode, KeyEvent e) { return false; }
        @Override public boolean onLongPress(MotionEvent event) { return false; }
        @Override public boolean readControlKey() { return false; }
        @Override public boolean readAltKey() { return false; }
        @Override public boolean readShiftKey() { return false; }
        @Override public boolean readFnKey() { return false; }
        @Override public boolean onCodePoint(int codePoint, boolean ctrlDown, TerminalSession session) { return false; }
        @Override public void onEmulatorSet() {}
        @Override public void logError(String tag, String message) {}
        @Override public void logWarn(String tag, String message) {}
        @Override public void logInfo(String tag, String message) {}
        @Override public void logDebug(String tag, String message) {}
        @Override public void logVerbose(String tag, String message) {}
        @Override public void logStackTraceWithMessage(String tag, String message, Exception e) {}
        @Override public void logStackTrace(String tag, Exception e) {}
    }

    @Test
    public void onCreateInputConnection_setsNoExtractUiFlag() {
        TerminalView view = newView();

        EditorInfo outAttrs = new EditorInfo();
        InputConnection ic = view.onCreateInputConnection(outAttrs);

        assertNotNull("onCreateInputConnection must return a connection", ic);
        assertNotEquals(
                "IME_FLAG_NO_EXTRACT_UI must be set so the IME does not "
                        + "render an extracted-text mirror over our cells",
                0,
                outAttrs.imeOptions & EditorInfo.IME_FLAG_NO_EXTRACT_UI);
    }

    @Test
    public void onCreateInputConnection_keepsNoFullscreenFlag() {
        TerminalView view = newView();

        EditorInfo outAttrs = new EditorInfo();
        view.onCreateInputConnection(outAttrs);

        assertNotEquals(
                "IME_FLAG_NO_FULLSCREEN must remain set so landscape IMEs "
                        + "do not cover the whole terminal",
                0,
                outAttrs.imeOptions & EditorInfo.IME_FLAG_NO_FULLSCREEN);
    }

    @Test
    public void inputConnection_getExtractedText_returnsNull() {
        TerminalView view = newView();
        InputConnection ic = view.onCreateInputConnection(new EditorInfo());

        ExtractedTextRequest request = new ExtractedTextRequest();
        assertNull(
                "getExtractedText must return null so the IME has no text "
                        + "to mirror back to the user",
                ic.getExtractedText(request, 0));
    }

    @Test
    public void editorInfoFlags_haveBothExpectedBits() {
        TerminalView view = newView();
        EditorInfo outAttrs = new EditorInfo();
        view.onCreateInputConnection(outAttrs);

        int expected = EditorInfo.IME_FLAG_NO_FULLSCREEN
                | EditorInfo.IME_FLAG_NO_EXTRACT_UI;
        assertEquals(
                "imeOptions should be exactly NO_FULLSCREEN | NO_EXTRACT_UI",
                expected,
                outAttrs.imeOptions);
    }
}
