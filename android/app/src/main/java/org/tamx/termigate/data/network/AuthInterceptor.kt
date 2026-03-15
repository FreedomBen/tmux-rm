package org.tamx.termigate.data.network

import io.ktor.client.plugins.api.createClientPlugin
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.header
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

sealed class AuthEvent {
    data object TokenExpired : AuthEvent()
    data class RateLimited(val retryAfterSeconds: Int?) : AuthEvent()
}

val AuthPlugin = createClientPlugin("AuthPlugin", ::AuthPluginConfig) {
    val tokenProvider = pluginConfig.tokenProvider
    val authEvents = pluginConfig.authEvents

    onRequest { request, _ ->
        // Add bearer token to all requests except login
        if (!request.url.buildString().contains("/api/login")) {
            val token = tokenProvider()
            if (token != null) {
                request.header("Authorization", "Bearer $token")
            }
        }
    }

    onResponse { response ->
        val requestUrl = response.call.request.url.toString()

        // Handle 401 — token expired (skip for login endpoint)
        if (response.status == HttpStatusCode.Unauthorized &&
            !requestUrl.contains("/api/login")
        ) {
            authEvents.emit(AuthEvent.TokenExpired)
        }

        // Handle 429 — rate limited
        if (response.status == HttpStatusCode.TooManyRequests) {
            val retryAfter = response.headers["Retry-After"]?.toIntOrNull()
            authEvents.emit(AuthEvent.RateLimited(retryAfter))
        }
    }
}

class AuthPluginConfig {
    var tokenProvider: () -> String? = { null }
    internal val authEvents = MutableSharedFlow<AuthEvent>(extraBufferCapacity = 8)
    val events: SharedFlow<AuthEvent> get() = authEvents.asSharedFlow()
}
