package org.tamx.termigate.ui.sessions

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.tamx.termigate.data.model.Pane
import org.tamx.termigate.data.model.Session

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionListScreen(
    onPaneClicked: (String) -> Unit,
    onSettingsClicked: () -> Unit,
    viewModel: SessionListViewModel = hiltViewModel()
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }

    // Show errors as snackbar
    LaunchedEffect(state.error) {
        state.error?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.onDismissError()
        }
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        "termigate",
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.primary
                    )
                },
                actions = {
                    IconButton(onClick = onSettingsClicked) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface
                )
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = viewModel::onShowCreateDialog) {
                Icon(Icons.Default.Add, contentDescription = "New Session")
            }
        },
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { padding ->
        Column(modifier = Modifier.padding(padding)) {
            // Tmux status banner
            state.tmuxStatus?.let { status ->
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.errorContainer
                ) {
                    Text(
                        text = when (status) {
                            "no_server" -> "tmux server is not running"
                            "not_found" -> "tmux not found on server"
                            else -> status
                        },
                        modifier = Modifier.padding(12.dp),
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }

            PullToRefreshBox(
                isRefreshing = state.isLoading,
                onRefresh = viewModel::onRefresh,
                modifier = Modifier.fillMaxSize()
            ) {
                if (state.sessions.isEmpty() && !state.isLoading) {
                    // Empty state
                    Box(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                Icons.Default.MoreVert,
                                contentDescription = null,
                                modifier = Modifier.size(64.dp),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                            )
                            Spacer(modifier = Modifier.height(16.dp))
                            Text(
                                "No sessions",
                                style = MaterialTheme.typography.titleMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Text(
                                "Create one to get started",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                            )
                        }
                    }
                } else {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(
                            start = 16.dp, end = 16.dp, top = 8.dp, bottom = 88.dp
                        ),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(state.sessions, key = { it.name }) { session ->
                            SessionCard(
                                session = session,
                                onPaneClicked = onPaneClicked,
                                onRename = { viewModel.onShowRenameDialog(session.name) },
                                onDelete = { viewModel.onShowDeleteConfirmation(session.name) },
                                onCreateWindow = { viewModel.onCreateWindow(session.name) },
                                onSplitPane = viewModel::onSplitPane,
                                onDeletePane = viewModel::onDeletePane
                            )
                        }
                    }
                }
            }
        }
    }

    // Create session dialog
    if (state.showCreateDialog) {
        CreateSessionDialog(
            onDismiss = viewModel::onDismissCreateDialog,
            onCreate = viewModel::onCreateSession
        )
    }

    // Rename dialog
    state.showRenameDialog?.let { renameState ->
        RenameSessionDialog(
            currentName = renameState.sessionName,
            onDismiss = viewModel::onDismissRenameDialog,
            onRename = { newName -> viewModel.onRenameSession(renameState.sessionName, newName) }
        )
    }

    // Delete confirmation
    state.showDeleteConfirmation?.let { sessionName ->
        AlertDialog(
            onDismissRequest = viewModel::onDismissDeleteConfirmation,
            title = { Text("Kill Session") },
            text = { Text("Kill session \"$sessionName\"? All panes will be closed.") },
            confirmButton = {
                TextButton(onClick = { viewModel.onDeleteSession(sessionName) }) {
                    Text("Kill", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = viewModel::onDismissDeleteConfirmation) {
                    Text("Cancel")
                }
            }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SessionCard(
    session: Session,
    onPaneClicked: (String) -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onCreateWindow: () -> Unit,
    onSplitPane: (String, String) -> Unit,
    onDeletePane: (String) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) {
                onDelete()
            }
            false // Don't actually dismiss; the confirmation dialog handles it
        }
    )

    SwipeToDismissBox(
        state = dismissState,
        backgroundContent = {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = MaterialTheme.colorScheme.error,
                shape = CardDefaults.shape
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 20.dp),
                    contentAlignment = Alignment.CenterEnd
                ) {
                    Icon(
                        Icons.Default.Delete,
                        contentDescription = "Delete",
                        tint = MaterialTheme.colorScheme.onError
                    )
                }
            }
        },
        enableDismissFromStartToEnd = false
    ) {
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .animateContentSize(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surface
            )
        ) {
            Column {
                // Session header
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        // Bug 10 in ANDROID_DRIVE_01.md: tapping a session
                        // row only toggled an expand state, which felt like
                        // "nothing happened" — users expected the tap to
                        // open the session. When there is exactly one pane
                        // the tap is unambiguous, so navigate straight to
                        // it; otherwise fall back to expanding so the user
                        // can pick a pane.
                        .clickable {
                            val singlePane = session.panes.singleOrNull()
                            if (singlePane != null) {
                                onPaneClicked(singlePane.target)
                            } else {
                                expanded = !expanded
                            }
                        }
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = session.name,
                            style = MaterialTheme.typography.titleMedium,
                            fontFamily = FontFamily.Monospace
                        )
                        Row {
                            Text(
                                text = "${session.windows} window${if (session.windows != 1) "s" else ""}" +
                                        " \u00b7 ${session.panes.size} pane${if (session.panes.size != 1) "s" else ""}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            if (session.attached) {
                                Text(
                                    text = " \u00b7 attached",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.primary
                                )
                            }
                        }
                    }

                    // Session actions
                    var showMenu by remember { mutableStateOf(false) }
                    Box {
                        IconButton(onClick = { showMenu = true }) {
                            Icon(
                                Icons.Default.Edit,
                                contentDescription = "Session actions",
                                modifier = Modifier.size(20.dp)
                            )
                        }
                        DropdownMenu(
                            expanded = showMenu,
                            onDismissRequest = { showMenu = false }
                        ) {
                            DropdownMenuItem(
                                text = { Text("Rename") },
                                onClick = { showMenu = false; onRename() }
                            )
                            DropdownMenuItem(
                                text = { Text("New Window") },
                                onClick = { showMenu = false; onCreateWindow() }
                            )
                            DropdownMenuItem(
                                text = {
                                    Text("Kill Session", color = MaterialTheme.colorScheme.error)
                                },
                                onClick = { showMenu = false; onDelete() }
                            )
                        }
                    }

                    Icon(
                        if (expanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                        contentDescription = if (expanded) "Collapse" else "Expand"
                    )
                }

                // Expanded pane list
                if (expanded && session.panes.isNotEmpty()) {
                    HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

                    val panesByWindow = session.panes.groupBy { it.windowIndex }
                    panesByWindow.entries.forEachIndexed { windowIdx, (windowIndex, panes) ->
                        if (windowIdx > 0) {
                            HorizontalDivider(
                                modifier = Modifier.padding(horizontal = 32.dp),
                                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)
                            )
                        }
                        Text(
                            text = "Window $windowIndex",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 16.dp, top = 8.dp)
                        )
                        panes.forEach { pane ->
                            PaneRow(
                                pane = pane,
                                onClick = { onPaneClicked(pane.target) },
                                onSplitHorizontal = { onSplitPane(pane.target, "horizontal") },
                                onSplitVertical = { onSplitPane(pane.target, "vertical") },
                                onDelete = { onDeletePane(pane.target) }
                            )
                        }
                    }
                    Spacer(modifier = Modifier.height(8.dp))
                }
            }
        }
    }
}

@Composable
private fun PaneRow(
    pane: Pane,
    onClick: () -> Unit,
    onSplitHorizontal: () -> Unit,
    onSplitVertical: () -> Unit,
    onDelete: () -> Unit
) {
    var showMenu by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            Icons.Default.MoreVert,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = MaterialTheme.colorScheme.primary
        )
        Spacer(modifier = Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = pane.command,
                style = MaterialTheme.typography.bodyMedium,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = "pane ${pane.index} \u00b7 ${pane.width}x${pane.height}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Box {
            IconButton(
                onClick = { showMenu = true },
                modifier = Modifier.size(32.dp)
            ) {
                Icon(
                    Icons.Default.Add,
                    contentDescription = "Pane actions",
                    modifier = Modifier.size(16.dp)
                )
            }
            DropdownMenu(
                expanded = showMenu,
                onDismissRequest = { showMenu = false }
            ) {
                DropdownMenuItem(
                    text = { Text("Split Horizontal") },
                    leadingIcon = { Icon(Icons.Default.Add, null, modifier = Modifier.size(18.dp)) },
                    onClick = { showMenu = false; onSplitHorizontal() }
                )
                DropdownMenuItem(
                    text = { Text("Split Vertical") },
                    leadingIcon = { Icon(Icons.Default.Add, null, modifier = Modifier.size(18.dp)) },
                    onClick = { showMenu = false; onSplitVertical() }
                )
                DropdownMenuItem(
                    text = { Text("Kill Pane", color = MaterialTheme.colorScheme.error) },
                    leadingIcon = {
                        Icon(
                            Icons.Default.Delete, null,
                            modifier = Modifier.size(18.dp),
                            tint = MaterialTheme.colorScheme.error
                        )
                    },
                    onClick = { showMenu = false; onDelete() }
                )
            }
        }
    }
}

private val SESSION_NAME_REGEX = Regex("^[a-zA-Z0-9_-]+$")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CreateSessionDialog(
    onDismiss: () -> Unit,
    onCreate: (String, String?) -> Unit
) {
    var name by remember { mutableStateOf("") }
    var command by remember { mutableStateOf("") }
    val nameError = name.isNotEmpty() && !SESSION_NAME_REGEX.matches(name)

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(modifier = Modifier.padding(horizontal = 24.dp, vertical = 16.dp)) {
            Text(
                "New Session",
                style = MaterialTheme.typography.titleLarge
            )
            Spacer(modifier = Modifier.height(16.dp))

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Session Name") },
                placeholder = { Text("my-session") },
                singleLine = true,
                isError = nameError,
                supportingText = if (nameError) {
                    { Text("Only letters, numbers, hyphens, and underscores") }
                } else null,
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(modifier = Modifier.height(8.dp))

            OutlinedTextField(
                value = command,
                onValueChange = { command = it },
                label = { Text("Command (optional)") },
                placeholder = { Text("e.g. htop") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(modifier = Modifier.height(16.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End
            ) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Spacer(modifier = Modifier.width(8.dp))
                TextButton(
                    onClick = { onCreate(name, command) },
                    enabled = name.isNotBlank() && !nameError
                ) { Text("Create") }
            }
            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}

@Composable
private fun RenameSessionDialog(
    currentName: String,
    onDismiss: () -> Unit,
    onRename: (String) -> Unit
) {
    var newName by remember { mutableStateOf(currentName) }
    val nameError = newName.isNotEmpty() && !SESSION_NAME_REGEX.matches(newName)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename Session") },
        text = {
            OutlinedTextField(
                value = newName,
                onValueChange = { newName = it },
                label = { Text("New Name") },
                singleLine = true,
                isError = nameError,
                supportingText = if (nameError) {
                    { Text("Only letters, numbers, hyphens, and underscores") }
                } else null,
                modifier = Modifier.fillMaxWidth()
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onRename(newName) },
                enabled = newName.isNotBlank() && !nameError && newName != currentName
            ) { Text("Rename") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    )
}
