defmodule Termigate.MCP.Tools.SplitPane do
  @moduledoc "Split a tmux pane horizontally or vertically."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.MCP.TargetHelper
  alias Termigate.TmuxManager

  schema do
    field(:target, :string, required: true, description: "Pane target (e.g. 'session:0.0')")

    field(:direction, :string,
      values: ["horizontal", "vertical"],
      description: "Split direction (default: horizontal)"
    )
  end

  @impl true
  def execute(%{target: target} = params, frame) do
    direction =
      case params[:direction] do
        "vertical" -> :vertical
        _ -> :horizontal
      end

    # Get panes before split to identify the new pane
    {:ok, session} = TargetHelper.session_from_target(target)
    before_panes = get_all_pane_targets(session)

    case TmuxManager.split_pane(target, direction) do
      {:ok, _} ->
        after_panes = get_all_pane_targets(session)
        new_panes = after_panes -- before_panes

        new_target = List.first(new_panes) || target

        data = %{
          original_target: target,
          new_target: new_target,
          direction: to_string(direction)
        }

        {:reply, Response.json(Response.tool(), data), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to split pane: #{reason}"), frame}
    end
  end

  defp get_all_pane_targets(session) do
    case TmuxManager.list_panes(session) do
      {:ok, panes_by_window} ->
        panes_by_window
        |> Map.values()
        |> List.flatten()
        |> Enum.map(&TargetHelper.pane_target/1)

      _ ->
        []
    end
  end
end
