defmodule TmuxRm.Tmux.CommandRunnerBehaviour do
  @doc "Run a tmux command with the given arguments. Returns stdout on success."
  @callback run(args :: [String.t()]) ::
              {:ok, String.t()} | {:error, {String.t(), non_neg_integer()}}

  @doc "Run a tmux command. Raises on failure."
  @callback run!(args :: [String.t()]) :: String.t()
end
