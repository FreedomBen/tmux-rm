package org.tamx.termigate.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class Session(
    val name: String,
    val windows: Int,
    val attached: Boolean,
    val created: Long? = null,
    val panes: List<Pane> = emptyList()
)

@Serializable
data class Pane(
    @SerialName("session_name")
    val sessionName: String,
    @SerialName("window_index")
    val windowIndex: Int,
    val index: Int,
    val width: Int,
    val height: Int,
    val command: String,
    @SerialName("pane_id")
    val paneId: String
) {
    val target: String get() = "$sessionName:$windowIndex.$index"
}

@Serializable
data class QuickAction(
    val id: String? = null,
    val label: String,
    val command: String,
    val confirm: Boolean = false,
    val color: String = "default",
    val icon: String? = null
)

@Serializable
data class LoginResponse(
    val token: String,
    @SerialName("expires_in")
    val expiresIn: Long
)

@Serializable
data class SessionsResponse(
    val sessions: List<Session>
)

@Serializable
data class QuickActionsResponse(
    @SerialName("quick_actions")
    val quickActions: List<QuickAction>
)

@Serializable
data class LoginRequest(
    val username: String,
    val password: String
)

@Serializable
data class CreateSessionRequest(
    val name: String,
    val command: String? = null
)

@Serializable
data class RenameSessionRequest(
    @SerialName("new_name")
    val newName: String
)

@Serializable
data class SplitPaneRequest(
    val direction: String
)

@Serializable
data class ReorderQuickActionsRequest(
    val ids: List<String>
)

@Serializable
data class StatusResponse(
    val status: String
)

@Serializable
data class ErrorResponse(
    val error: String
)

@Serializable
data class ConfigResponse(
    val config: AppConfig
)

@Serializable
data class AppConfig(
    val auth: Boolean = true
)
