defmodule Termigate.MCP.Tools.ReadHistory do
  @moduledoc "Read scrollback history from a tmux pane's buffer."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.MCP.AnsiStripper
  alias Termigate.PaneStream
  alias Termigate.TmuxManager

  schema do
    field(:target, :string, required: true, description: "Pane target (e.g. 'session:0.0')")
    field(:lines, :integer, description: "Number of scrollback lines to capture (default: 1000)")
    field(:raw, :boolean, description: "Include ANSI escape sequences (default: false)")
  end

  @impl true
  def execute(%{target: target} = params, frame) do
    lines = params[:lines] || 1000
    raw = params[:raw] || false

    # Try PaneStream buffer first (faster, more recent), fall back to capture_pane
    content =
      case PaneStream.read_buffer(target) do
        {:ok, buffer_data} when byte_size(buffer_data) > 0 ->
          buffer_data

        _ ->
          case TmuxManager.capture_pane(target, lines: lines) do
            {:ok, data} -> data
            {:error, _} -> nil
          end
      end

    case content do
      nil ->
        {:reply, Response.error(Response.tool(), "Pane not found or no history: #{target}"),
         frame}

      data ->
        data = if raw, do: data, else: AnsiStripper.strip(data)

        result = %{
          target: target,
          content: data,
          bytes: byte_size(data)
        }

        {:reply, Response.json(Response.tool(), result), frame}
    end
  end
end
