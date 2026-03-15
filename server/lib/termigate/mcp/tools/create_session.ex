defmodule Termigate.MCP.Tools.CreateSession do
  @moduledoc "Create a new tmux session."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias Termigate.TmuxManager

  schema do
    field(:name, :string,
      required: true,
      description: "Session name (alphanumeric, hyphens, underscores)"
    )

    field(:command, :string, description: "Command to run in the initial pane")
    field(:cols, :integer, description: "Terminal width (default: 120)")
    field(:rows, :integer, description: "Terminal height (default: 40)")
  end

  @impl true
  def execute(%{name: name} = params, frame) do
    opts =
      []
      |> maybe_add(:command, params[:command])
      |> maybe_add(:cols, params[:cols])
      |> maybe_add(:rows, params[:rows])

    case TmuxManager.create_session(name, opts) do
      {:ok, %{name: created_name}} ->
        data = %{
          name: created_name,
          target: "#{created_name}:0.0"
        }

        {:reply, Response.json(Response.tool(), data), frame}

      {:error, :invalid_name} ->
        {:reply,
         Response.error(
           Response.tool(),
           "Invalid session name. Use only alphanumeric characters, hyphens, and underscores."
         ), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), "Failed to create session: #{reason}"), frame}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
