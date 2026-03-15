defmodule Termigate.MCP.AnsiStripper do
  @moduledoc "Strips ANSI escape sequences from terminal output."

  @ansi_regex ~r/(?:\e\[[0-9;]*[A-Za-z]|\e\][^\a]*\a|\e[()][0-2]|\e[>=<]|\e\[\?[0-9;]*[hl]|\e\[[0-9]*[ABCDJKHS])/

  @doc "Remove ANSI escape sequences from the given string."
  @spec strip(binary()) :: binary()
  def strip(data) when is_binary(data) do
    Regex.replace(@ansi_regex, data, "")
  end
end
