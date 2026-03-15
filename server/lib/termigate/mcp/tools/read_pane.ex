defmodule Termigate.MCP.Tools.ReadPane do
  @moduledoc "Read the current visible content of a tmux pane."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.MCP.AnsiStripper
  alias Termigate.TmuxManager

  schema do
    field(:target, :string, required: true, description: "Pane target (e.g. 'session:0.0')")
    field(:raw, :boolean, description: "Include ANSI escape sequences (default: false)")
  end

  @impl true
  def execute(%{target: target} = params, frame) do
    raw = params[:raw] || false

    case TmuxManager.capture_pane(target) do
      {:ok, content} ->
        content = if raw, do: content, else: AnsiStripper.strip(content)

        data = %{
          target: target,
          content: content
        }

        {:reply, Response.json(Response.tool(), data), frame}

      {:error, :pane_not_found} ->
        {:reply, Response.error(Response.tool(), "Pane not found: #{target}"), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to read pane: #{inspect(reason)}"),
         frame}
    end
  end
end
