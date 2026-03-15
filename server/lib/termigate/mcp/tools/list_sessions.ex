defmodule Termigate.MCP.Tools.ListSessions do
  @moduledoc "List all tmux sessions with their metadata."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.TmuxManager

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case TmuxManager.list_sessions() do
      {:ok, sessions} ->
        data = Enum.map(sessions, &serialize_session/1)
        {:reply, Response.json(Response.tool(), data), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to list sessions: #{reason}"), frame}
    end
  end

  defp serialize_session(session) do
    %{
      name: session.name,
      windows: session.windows,
      created: if(session.created, do: DateTime.to_iso8601(session.created)),
      attached: session.attached?
    }
  end
end
