defmodule TmuxRm.StubCommandRunner do
  @moduledoc "Default stub for CommandRunnerBehaviour used during test app boot."
  @behaviour TmuxRm.Tmux.CommandRunnerBehaviour

  @impl true
  def run(["list-sessions" | _]),
    do: {:error, {"no server running on /tmp/tmux-default/default", 1}}

  def run(["list-panes" | _]), do: {:error, {"no server running", 1}}
  def run(["has-session" | _]), do: {:error, {"no server running", 1}}
  def run(_args), do: {:error, {"stubbed command runner", 1}}

  @impl true
  def run!(args) do
    case run(args) do
      {:ok, output} -> output
      {:error, {msg, _}} -> raise "StubCommandRunner: #{msg}"
    end
  end
end
