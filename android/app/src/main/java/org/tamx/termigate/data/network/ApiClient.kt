package org.tamx.termigate.data.network

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import org.tamx.termigate.data.model.AppConfig
import org.tamx.termigate.data.model.ConfigResponse
import org.tamx.termigate.data.model.CreateSessionRequest
import org.tamx.termigate.data.model.ErrorResponse
import org.tamx.termigate.data.model.LoginRequest
import org.tamx.termigate.data.model.LoginResponse
import org.tamx.termigate.data.model.QuickAction
import org.tamx.termigate.data.model.QuickActionsResponse
import org.tamx.termigate.data.model.RenameSessionRequest
import org.tamx.termigate.data.model.ReorderQuickActionsRequest
import org.tamx.termigate.data.model.Session
import org.tamx.termigate.data.model.SessionsResponse
import org.tamx.termigate.data.model.SplitPaneRequest

class ApiClient(
    private val client: HttpClient,
    private val serverUrl: () -> String
) {
    private fun url(path: String): String = "${serverUrl().trimEnd('/')}$path"

    // Auth

    suspend fun login(username: String, password: String): Result<LoginResponse> = runApi {
        client.post(url("/api/login")) {
            contentType(ContentType.Application.Json)
            setBody(LoginRequest(username, password))
        }.body<LoginResponse>()
    }

    // Sessions

    suspend fun listSessions(): Result<List<Session>> = runApi {
        client.get(url("/api/sessions")).body<SessionsResponse>().sessions
    }

    suspend fun createSession(name: String, command: String? = null): Result<Unit> = runApi {
        client.post(url("/api/sessions")) {
            contentType(ContentType.Application.Json)
            setBody(CreateSessionRequest(name, command))
        }
        Unit
    }

    suspend fun deleteSession(name: String): Result<Unit> = runApi {
        client.delete(url("/api/sessions/$name"))
        Unit
    }

    suspend fun renameSession(name: String, newName: String): Result<Unit> = runApi {
        client.put(url("/api/sessions/$name")) {
            contentType(ContentType.Application.Json)
            setBody(RenameSessionRequest(newName))
        }
        Unit
    }

    suspend fun createWindow(sessionName: String): Result<Unit> = runApi {
        client.post(url("/api/sessions/$sessionName/windows"))
        Unit
    }

    // Panes

    suspend fun splitPane(target: String, direction: String): Result<Unit> = runApi {
        client.post(url("/api/panes/$target/split")) {
            contentType(ContentType.Application.Json)
            setBody(SplitPaneRequest(direction))
        }
        Unit
    }

    suspend fun deletePane(target: String): Result<Unit> = runApi {
        client.delete(url("/api/panes/$target"))
        Unit
    }

    // Quick Actions

    suspend fun getQuickActions(): Result<List<QuickAction>> = runApi {
        client.get(url("/api/quick-actions")).body<QuickActionsResponse>().quickActions
    }

    suspend fun createQuickAction(action: QuickAction): Result<List<QuickAction>> = runApi {
        client.post(url("/api/quick-actions")) {
            contentType(ContentType.Application.Json)
            setBody(action)
        }.body<QuickActionsResponse>().quickActions
    }

    suspend fun updateQuickAction(id: String, action: QuickAction): Result<List<QuickAction>> = runApi {
        client.put(url("/api/quick-actions/$id")) {
            contentType(ContentType.Application.Json)
            setBody(action)
        }.body<QuickActionsResponse>().quickActions
    }

    suspend fun deleteQuickAction(id: String): Result<Unit> = runApi {
        client.delete(url("/api/quick-actions/$id"))
        Unit
    }

    suspend fun reorderQuickActions(ids: List<String>): Result<List<QuickAction>> = runApi {
        client.put(url("/api/quick-actions/order")) {
            contentType(ContentType.Application.Json)
            setBody(ReorderQuickActionsRequest(ids))
        }.body<QuickActionsResponse>().quickActions
    }

    // Config

    suspend fun getConfig(): Result<AppConfig> = runApi {
        client.get(url("/api/config")).body<ConfigResponse>().config
    }

    // Unauthenticated probe to check if auth is required
    suspend fun probeAuthRequired(): Boolean {
        return try {
            val response: HttpResponse = client.get(url("/api/sessions"))
            !response.status.isSuccess()
        } catch (_: Exception) {
            true
        }
    }

    private inline fun <T> runApi(block: () -> T): Result<T> {
        return try {
            Result.success(block())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
