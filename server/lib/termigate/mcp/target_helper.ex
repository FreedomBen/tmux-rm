defmodule Termigate.MCP.TargetHelper do
  @moduledoc "Helpers for constructing and validating tmux pane targets."

  alias Termigate.Tmux.Pane

  @target_regex ~r/^[a-zA-Z0-9_-]+(:[0-9]+(\.[0-9]+)?)?$/

  @doc "Construct a pane target string from a Pane struct."
  @spec pane_target(Pane.t()) :: String.t()
  def pane_target(%Pane{} = pane) do
    "#{pane.session_name}:#{pane.window_index}.#{pane.index}"
  end

  @doc "Extract the session name from a target string."
  @spec session_from_target(String.t()) :: {:ok, String.t()} | {:error, :invalid_target}
  def session_from_target(target) when is_binary(target) do
    case String.split(target, ":", parts: 2) do
      [session | _] when session != "" -> {:ok, session}
      _ -> {:error, :invalid_target}
    end
  end

  @doc "Check if a target string is valid."
  @spec valid_target?(String.t()) :: boolean()
  def valid_target?(target) when is_binary(target) do
    String.match?(target, @target_regex)
  end

  def valid_target?(_), do: false
end
