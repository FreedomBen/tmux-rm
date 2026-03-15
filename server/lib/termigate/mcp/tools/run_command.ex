defmodule Termigate.MCP.Tools.RunCommand do
  @moduledoc "Run a command in a tmux pane and wait for it to complete, returning the output and exit code."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.MCP.Workflows

  schema do
    field(:target, :string, required: true, description: "Pane target (e.g. 'session:0.0')")
    field(:command, :string, required: true, description: "Shell command to execute")
    field(:timeout_seconds, :integer, description: "Timeout in seconds (default: 30, max: 300)")
    field(:raw, :boolean, description: "Include ANSI escape sequences (default: false)")
  end

  @impl true
  def execute(%{target: target, command: command} = params, frame) do
    timeout_ms = (params[:timeout_seconds] || 30) * 1000
    raw = params[:raw] || false

    case Workflows.RunCommand.run(target, command, timeout_ms: timeout_ms, raw: raw) do
      {:ok, result} ->
        {:reply, Response.json(Response.tool(), Map.put(result, :target, target)), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to run command: #{inspect(reason)}"),
         frame}
    end
  end
end
