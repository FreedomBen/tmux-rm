defmodule Termigate.MCP.Tools.RunCommandInNewSession do
  @moduledoc "Create a temporary tmux session, run a command, return the output, and optionally clean up."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.MCP.Workflows
  alias Termigate.TmuxManager

  schema do
    field(:command, :string, required: true, description: "Shell command to execute")
    field(:session_name, :string, description: "Session name (auto-generated if not provided)")

    field(:cleanup, :boolean,
      description: "Kill the session after command completes (default: true)"
    )

    field(:timeout_seconds, :integer, description: "Timeout in seconds (default: 30, max: 300)")
    field(:raw, :boolean, description: "Include ANSI escape sequences (default: false)")
  end

  @impl true
  def execute(%{command: command} = params, frame) do
    session_name = params[:session_name] || generate_session_name()
    cleanup = if(params[:cleanup] == false, do: false, else: true)
    timeout_ms = (params[:timeout_seconds] || 30) * 1000
    raw = params[:raw] || false

    with {:ok, %{name: name}} <- TmuxManager.create_session(session_name) do
      target = "#{name}:0.0"

      result =
        case Workflows.RunCommand.run(target, command, timeout_ms: timeout_ms, raw: raw) do
          {:ok, result} ->
            if cleanup, do: TmuxManager.kill_session(name)
            data = Map.merge(result, %{target: target, session: name, cleaned_up: cleanup})
            {:reply, Response.json(Response.tool(), data), frame}

          {:error, reason} ->
            if cleanup, do: TmuxManager.kill_session(name)

            {:reply, Response.error(Response.tool(), "Command failed: #{inspect(reason)}"), frame}
        end

      result
    else
      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to create session: #{inspect(reason)}"),
         frame}
    end
  end

  defp generate_session_name do
    short_id = :crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false)
    "mcp-#{short_id}"
  end
end
