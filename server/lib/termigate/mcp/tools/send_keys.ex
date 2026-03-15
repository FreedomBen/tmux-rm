defmodule Termigate.MCP.Tools.SendKeys do
  @moduledoc "Send keyboard input to a tmux pane. Auto-starts streaming if needed."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.PaneStream

  schema do
    field(:target, :string, required: true, description: "Pane target (e.g. 'session:0.0')")
    field(:keys, :string, required: true, description: "Text/keys to send. Use \\n for Enter.")
  end

  @impl true
  def execute(%{target: target, keys: keys}, frame) do
    case PaneStream.send_keys(target, keys) do
      :ok ->
        {:reply, Response.text(Response.tool(), "Keys sent to #{target}."), frame}

      {:error, :input_too_large} ->
        {:reply, Response.error(Response.tool(), "Input too large (max 128 KiB)."), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to send keys: #{inspect(reason)}"),
         frame}
    end
  end
end
