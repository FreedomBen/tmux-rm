defmodule Termigate.MCP.Tools.ResizePane do
  @moduledoc "Resize a tmux pane to specific dimensions."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.TmuxManager

  schema do
    field(:target, :string, required: true, description: "Pane target (e.g. 'session:0.0')")
    field(:cols, :integer, description: "New width in columns")
    field(:rows, :integer, description: "New height in rows")
  end

  @impl true
  def execute(%{target: target} = params, frame) do
    opts =
      []
      |> then(fn o -> if params[:cols], do: Keyword.put(o, :x, params[:cols]), else: o end)
      |> then(fn o -> if params[:rows], do: Keyword.put(o, :y, params[:rows]), else: o end)

    if opts == [] do
      {:reply, Response.error(Response.tool(), "Specify at least one of cols or rows."), frame}
    else
      case TmuxManager.resize_pane(target, opts) do
        :ok ->
          data = %{target: target, cols: params[:cols], rows: params[:rows]}
          {:reply, Response.json(Response.tool(), data), frame}

        {:error, reason} ->
          {:reply, Response.error(Response.tool(), "Failed to resize pane: #{reason}"), frame}
      end
    end
  end
end
