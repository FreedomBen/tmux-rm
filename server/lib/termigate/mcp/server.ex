defmodule Termigate.MCP.Server do
  @moduledoc "MCP server for AI agent access to tmux sessions."

  use Hermes.Server,
    name: "termigate",
    version: "0.1.0",
    capabilities: [:tools]

  # Tier 1: Core tmux operations
  component(Termigate.MCP.Tools.ListSessions, name: "tmux_list_sessions")
  component(Termigate.MCP.Tools.ListPanes, name: "tmux_list_panes")
  component(Termigate.MCP.Tools.CreateSession, name: "tmux_create_session")
  component(Termigate.MCP.Tools.KillSession, name: "tmux_kill_session")
  component(Termigate.MCP.Tools.SplitPane, name: "tmux_split_pane")
  component(Termigate.MCP.Tools.KillPane, name: "tmux_kill_pane")
  component(Termigate.MCP.Tools.SendKeys, name: "tmux_send_keys")
  component(Termigate.MCP.Tools.ReadPane, name: "tmux_read_pane")
  component(Termigate.MCP.Tools.ReadHistory, name: "tmux_read_history")
  component(Termigate.MCP.Tools.ResizePane, name: "tmux_resize_pane")

  # Tier 2: Workflow tools
  component(Termigate.MCP.Tools.RunCommand, name: "tmux_run_command")
  component(Termigate.MCP.Tools.RunCommandInNewSession, name: "tmux_run_command_in_new_session")
  component(Termigate.MCP.Tools.WaitForOutput, name: "tmux_wait_for_output")
  component(Termigate.MCP.Tools.SendAndRead, name: "tmux_send_and_read")
end
