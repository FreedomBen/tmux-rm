package org.tamx.termigate.ui.login

import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.tamx.termigate.data.repository.AuthRepository

/**
 * Codex security review (archived-docs/15_CODEX_SECURITY_REVIEW.md):
 * tapping Connect with an `http://` server URL must surface an explicit
 * cleartext warning before any login request fires, and must not send
 * credentials until the user confirms.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class LoginViewModelInsecureConfirmationTest {

    private val dispatcher = StandardTestDispatcher()
    private lateinit var authRepository: AuthRepository

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        authRepository = mockk(relaxed = true)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun http_url_prompts_for_confirmation_and_does_not_probe() = runTest(dispatcher) {
        val vm = LoginViewModel(authRepository)
        vm.onServerUrlChanged("http://example.com:8888")
        vm.onUsernameChanged("alice")
        vm.onPasswordChanged("hunter2")

        vm.onLoginClicked()
        dispatcher.scheduler.advanceUntilIdle()

        val state = vm.uiState.value
        assertTrue(
            "http:// click must raise the cleartext confirmation",
            state.pendingInsecureConfirmation
        )
        assertFalse("must not be loading until user confirms", state.isLoading)
        // probeAuthRequired must not be invoked before confirmation.
        io.mockk.coVerify(exactly = 0) { authRepository.probeAuthRequired(any()) }
    }

    @Test
    fun cancelling_confirmation_clears_pending_flag() = runTest(dispatcher) {
        val vm = LoginViewModel(authRepository)
        vm.onServerUrlChanged("http://example.com")
        vm.onLoginClicked()

        vm.onCancelInsecureConnection()

        assertFalse(vm.uiState.value.pendingInsecureConfirmation)
        io.mockk.coVerify(exactly = 0) { authRepository.probeAuthRequired(any()) }
    }

    @Test
    fun confirming_proceeds_with_login_flow() = runTest(dispatcher) {
        coEvery { authRepository.probeAuthRequired("http://example.com") } returns false
        val vm = LoginViewModel(authRepository)
        vm.onServerUrlChanged("http://example.com")
        vm.onLoginClicked()
        assertTrue(vm.uiState.value.pendingInsecureConfirmation)

        vm.onConfirmInsecureConnection()
        dispatcher.scheduler.advanceUntilIdle()

        val state = vm.uiState.value
        assertFalse(state.pendingInsecureConfirmation)
        assertTrue("no-auth probe should mark login complete", state.loginSuccess)
    }

    @Test
    fun https_url_skips_confirmation() = runTest(dispatcher) {
        coEvery { authRepository.probeAuthRequired("https://example.com") } returns false
        val vm = LoginViewModel(authRepository)
        vm.onServerUrlChanged("https://example.com")

        vm.onLoginClicked()
        dispatcher.scheduler.advanceUntilIdle()

        val state = vm.uiState.value
        assertFalse(state.pendingInsecureConfirmation)
        assertTrue(state.loginSuccess)
    }

    @Test
    fun bare_host_skips_confirmation() = runTest(dispatcher) {
        // Bare hosts now default to https in candidateServerUrls, so the
        // confirmation flow should not fire for unprefixed input.
        coEvery { authRepository.probeAuthRequired("example.com") } returns false
        val vm = LoginViewModel(authRepository)
        vm.onServerUrlChanged("example.com")

        vm.onLoginClicked()
        dispatcher.scheduler.advanceUntilIdle()

        assertFalse(vm.uiState.value.pendingInsecureConfirmation)
    }

    @Test
    fun blank_url_shows_error_without_confirmation() = runTest(dispatcher) {
        val vm = LoginViewModel(authRepository)

        vm.onLoginClicked()

        val state = vm.uiState.value
        assertEquals("Server URL is required", state.error)
        assertFalse(state.pendingInsecureConfirmation)
    }
}
