defmodule Termigate.MCP.Workflows.WaitForOutput do
  @moduledoc "Watches pane output for a regex pattern match."

  alias Termigate.MCP.AnsiStripper
  alias Termigate.PaneStream

  @max_timeout_ms 300_000
  @context_lines 5

  @doc """
  Wait for output matching a regex pattern in the given pane.
  Returns `{:ok, result}` or `{:error, reason}`.

  Result map contains:
  - `matched` — boolean
  - `match` — the matched text (if found)
  - `context` — surrounding lines for context
  - `timed_out` — boolean
  """
  def wait(target, pattern_str, opts \\ []) do
    timeout = opts |> Keyword.get(:timeout_ms, 60_000) |> min(@max_timeout_ms)
    raw = Keyword.get(opts, :raw, false)

    case Regex.compile(pattern_str) do
      {:ok, regex} ->
        do_wait(target, regex, timeout, raw)

      {:error, reason} ->
        {:error, "Invalid regex pattern: #{inspect(reason)}"}
    end
  end

  defp do_wait(target, regex, timeout, raw) do
    # Check existing buffer first
    case PaneStream.read_buffer(target) do
      {:ok, buffer} when byte_size(buffer) > 0 ->
        text = if raw, do: buffer, else: AnsiStripper.strip(buffer)

        if Regex.match?(regex, text) do
          {:ok, build_match_result(text, regex)}
        else
          watch_for_match(target, regex, timeout, raw)
        end

      _ ->
        watch_for_match(target, regex, timeout, raw)
    end
  end

  defp watch_for_match(target, regex, timeout, raw) do
    pubsub_topic = "pane:#{target}"
    Phoenix.PubSub.subscribe(Termigate.PubSub, pubsub_topic)

    deadline = System.monotonic_time(:millisecond) + timeout
    result = do_watch(target, regex, deadline, raw, [])

    Phoenix.PubSub.unsubscribe(Termigate.PubSub, pubsub_topic)
    result
  end

  defp do_watch(target, regex, deadline, raw, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:ok, %{matched: false, match: nil, context: nil, timed_out: true}}
    else
      receive do
        {:pane_output, ^target, data} ->
          new_acc = acc ++ [data]
          combined = IO.iodata_to_binary(new_acc)
          text = if raw, do: combined, else: AnsiStripper.strip(combined)

          if Regex.match?(regex, text) do
            {:ok, build_match_result(text, regex)}
          else
            do_watch(target, regex, deadline, raw, new_acc)
          end

        {:pane_dead, ^target} ->
          {:error, :pane_dead}
      after
        min(remaining, 100) ->
          do_watch(target, regex, deadline, raw, acc)
      end
    end
  end

  defp build_match_result(text, regex) do
    [match | _] = Regex.run(regex, text)

    lines = String.split(text, "\n")

    match_line_idx =
      Enum.find_index(lines, fn line -> Regex.match?(regex, line) end) || 0

    context_start = max(0, match_line_idx - @context_lines)
    context_end = min(length(lines) - 1, match_line_idx + @context_lines)

    context =
      lines
      |> Enum.slice(context_start..context_end)
      |> Enum.join("\n")

    %{matched: true, match: match, context: context, timed_out: false}
  end
end
