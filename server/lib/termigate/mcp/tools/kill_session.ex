defmodule Termigate.MCP.Tools.KillSession do
  @moduledoc "Kill (destroy) a tmux session and all its windows/panes."

  use Hermes.Server.Component,
    type: :tool,
    annotations: %{"destructiveHint" => true}

  alias Hermes.Server.Response
  alias Termigate.TmuxManager

  schema do
    field(:name, :string, required: true, description: "Session name to kill")
  end

  @impl true
  def execute(%{name: name}, frame) do
    case TmuxManager.kill_session(name) do
      :ok ->
        {:reply, Response.text(Response.tool(), "Session '#{name}' killed."), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to kill session: #{reason}"), frame}
    end
  end
end
