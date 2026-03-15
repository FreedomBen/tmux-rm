defmodule Termigate.MCP.Tools.KillPane do
  @moduledoc "Kill (close) a tmux pane."

  use Hermes.Server.Component,
    type: :tool,
    annotations: %{"destructiveHint" => true}

  alias Hermes.Server.Response
  alias Termigate.TmuxManager

  schema do
    field(:target, :string,
      required: true,
      description: "Pane target to kill (e.g. 'session:0.1')"
    )
  end

  @impl true
  def execute(%{target: target}, frame) do
    case TmuxManager.kill_pane(target) do
      :ok ->
        {:reply, Response.text(Response.tool(), "Pane '#{target}' killed."), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to kill pane: #{reason}"), frame}
    end
  end
end
