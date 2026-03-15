defmodule Termigate.MCP.Tools.WaitForOutput do
  @moduledoc "Wait for output matching a regex pattern in a tmux pane."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.MCP.Workflows

  schema do
    field(:target, :string, required: true, description: "Pane target (e.g. 'session:0.0')")
    field(:pattern, :string, required: true, description: "Regex pattern to match")
    field(:timeout_seconds, :integer, description: "Timeout in seconds (default: 60, max: 300)")
    field(:raw, :boolean, description: "Include ANSI escape sequences (default: false)")
  end

  @impl true
  def execute(%{target: target, pattern: pattern} = params, frame) do
    timeout_ms = (params[:timeout_seconds] || 60) * 1000
    raw = params[:raw] || false

    case Workflows.WaitForOutput.wait(target, pattern, timeout_ms: timeout_ms, raw: raw) do
      {:ok, result} ->
        {:reply, Response.json(Response.tool(), Map.put(result, :target, target)), frame}

      {:error, reason} when is_binary(reason) ->
        {:reply, Response.error(Response.tool(), reason), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed: #{inspect(reason)}"), frame}
    end
  end
end
