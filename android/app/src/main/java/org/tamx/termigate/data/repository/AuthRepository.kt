package org.tamx.termigate.data.repository

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.tamx.termigate.data.network.ApiClient
import org.tamx.termigate.data.network.AuthEvent
import org.tamx.termigate.data.network.AuthPluginConfig
import org.tamx.termigate.data.network.candidateServerUrls
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthRepository @Inject constructor(
    private val apiClient: ApiClient,
    private val prefs: AppPreferences,
    private val authPluginConfig: AuthPluginConfig
) {
    private val _isAuthenticated = MutableStateFlow(prefs.authToken != null)
    val isAuthenticated: StateFlow<Boolean> = _isAuthenticated.asStateFlow()

    private val _authRequired = MutableStateFlow<Boolean?>(null)
    val authRequired: StateFlow<Boolean?> = _authRequired.asStateFlow()

    val authEvents = authPluginConfig.events

    suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> {
        // prefs.serverUrl is set by probeAuthRequired, which selects the
        // reachable candidate URL (including any port fallback).
        prefs.lastUsername = username

        val result = apiClient.login(username, password)
        return result.map { response ->
            prefs.authToken = response.token
            _isAuthenticated.value = true
        }
    }

    suspend fun probeAuthRequired(serverUrl: String): Boolean {
        val candidates = candidateServerUrls(serverUrl)
        var lastFailure: Throwable? = null
        for (candidate in candidates) {
            try {
                val required = apiClient.probeAuthRequiredAt(candidate)
                prefs.serverUrl = candidate.trimEnd('/')
                _authRequired.value = required
                if (!required) {
                    _isAuthenticated.value = true
                }
                return required
            } catch (e: Exception) {
                lastFailure = e
            }
        }
        throw lastFailure ?: IllegalStateException("No server URL candidates to try")
    }

    fun getToken(): String? = prefs.authToken

    fun clearToken() {
        prefs.authToken = null
        _isAuthenticated.value = false
    }

    fun getServerUrl(): String? = prefs.serverUrl

    fun getLastUsername(): String? = prefs.lastUsername
}
