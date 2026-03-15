defmodule Termigate.MCP.Tools.ListPanes do
  @moduledoc "List all panes in a tmux session, grouped by window."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.MCP.TargetHelper
  alias Termigate.TmuxManager

  schema do
    field(:session, :string, required: true, description: "Session name")
  end

  @impl true
  def execute(%{session: session}, frame) do
    case TmuxManager.list_panes(session) do
      {:ok, panes_by_window} ->
        data =
          panes_by_window
          |> Enum.sort_by(fn {window_idx, _} -> window_idx end)
          |> Enum.map(fn {window_idx, panes} ->
            %{
              window: to_string(window_idx),
              panes: Enum.map(panes, &serialize_pane/1)
            }
          end)

        {:reply, Response.json(Response.tool(), data), frame}

      {:error, :session_not_found} ->
        {:reply, Response.error(Response.tool(), "Session not found: #{session}"), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to list panes: #{reason}"), frame}
    end
  end

  defp serialize_pane(pane) do
    %{
      target: TargetHelper.pane_target(pane),
      index: pane.index,
      width: pane.width,
      height: pane.height,
      command: pane.command,
      pane_id: pane.pane_id
    }
  end
end
