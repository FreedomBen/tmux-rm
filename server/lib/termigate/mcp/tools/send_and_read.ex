defmodule Termigate.MCP.Tools.SendAndRead do
  @moduledoc "Send input to a tmux pane, wait a short delay, then read the pane content."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.MCP.AnsiStripper
  alias Termigate.PaneStream
  alias Termigate.TmuxManager

  schema do
    field(:target, :string, required: true, description: "Pane target (e.g. 'session:0.0')")
    field(:keys, :string, required: true, description: "Text/keys to send. Use \\n for Enter.")

    field(:delay_ms, :integer,
      description: "Milliseconds to wait before reading (default: 500, max: 5000)"
    )

    field(:raw, :boolean, description: "Include ANSI escape sequences (default: false)")
  end

  @impl true
  def execute(%{target: target, keys: keys} = params, frame) do
    delay = params[:delay_ms] |> then(&((&1 || 500) |> max(50) |> min(5000)))
    raw = params[:raw] || false

    case PaneStream.send_keys(target, keys) do
      :ok ->
        Process.sleep(delay)

        case TmuxManager.capture_pane(target) do
          {:ok, content} ->
            content = if raw, do: content, else: AnsiStripper.strip(content)
            data = %{target: target, content: content}
            {:reply, Response.json(Response.tool(), data), frame}

          {:error, reason} ->
            {:reply,
             Response.error(Response.tool(), "Keys sent but failed to read: #{inspect(reason)}"),
             frame}
        end

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to send keys: #{inspect(reason)}"),
         frame}
    end
  end
end
