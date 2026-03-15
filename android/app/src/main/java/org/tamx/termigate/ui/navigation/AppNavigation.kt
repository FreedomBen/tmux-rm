package org.tamx.termigate.ui.navigation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.flow.collectLatest
import org.tamx.termigate.data.network.AuthEvent
import org.tamx.termigate.data.repository.AuthRepository
import org.tamx.termigate.ui.login.LoginScreen
import org.tamx.termigate.ui.sessions.SessionListScreen
import org.tamx.termigate.ui.terminal.TerminalScreen

object Routes {
    const val LOGIN = "login"
    const val SESSIONS = "sessions"
    const val TERMINAL = "terminal/{target}"
    const val SETTINGS = "settings"

    fun terminal(target: String) = "terminal/$target"
}

@Composable
fun AppNavigation(
    authRepository: AuthRepository,
    navController: NavHostController = rememberNavController()
) {
    // Global 401 handling — navigate to login, clear back stack
    LaunchedEffect(Unit) {
        authRepository.authEvents.collectLatest { event ->
            when (event) {
                is AuthEvent.TokenExpired -> {
                    authRepository.clearToken()
                    navController.navigate(Routes.LOGIN) {
                        popUpTo(0) { inclusive = true }
                    }
                }
                is AuthEvent.RateLimited -> { /* handled by individual screens */ }
            }
        }
    }

    val startDestination = if (authRepository.getToken() != null) {
        Routes.SESSIONS
    } else {
        Routes.LOGIN
    }

    NavHost(navController = navController, startDestination = startDestination) {
        composable(Routes.LOGIN) {
            LoginScreen(
                onLoginSuccess = {
                    navController.navigate(Routes.SESSIONS) {
                        popUpTo(Routes.LOGIN) { inclusive = true }
                    }
                }
            )
        }
        composable(Routes.SESSIONS) {
            SessionListScreen(
                onPaneClicked = { target ->
                    navController.navigate(Routes.terminal(target))
                },
                onSettingsClicked = {
                    navController.navigate(Routes.SETTINGS)
                }
            )
        }
        composable(Routes.TERMINAL) {
            TerminalScreen(
                onBack = { navController.popBackStack() },
                onNavigateToTarget = { newTarget ->
                    navController.navigate(Routes.terminal(newTarget)) {
                        popUpTo(Routes.SESSIONS)
                    }
                }
            )
        }
        composable(Routes.SETTINGS) {
            // Placeholder until Phase 7
        }
    }
}
