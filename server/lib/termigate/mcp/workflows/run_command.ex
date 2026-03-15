defmodule Termigate.MCP.Workflows.RunCommand do
  @moduledoc "Runs a command in a pane and waits for completion by detecting a unique marker."

  alias Termigate.MCP.AnsiStripper
  alias Termigate.PaneStream

  @max_timeout_ms 300_000
  @marker_prefix "__MCP_DONE_"

  @doc """
  Send a command to a pane and wait for it to complete.
  Returns `{:ok, result}` or `{:error, reason}`.

  Result map contains:
  - `output` — command output (ANSI stripped unless raw: true)
  - `exit_code` — integer exit code
  - `timed_out` — boolean
  """
  def run(target, command, opts \\ []) do
    timeout = opts |> Keyword.get(:timeout_ms, 30_000) |> min(@max_timeout_ms)
    raw = Keyword.get(opts, :raw, false)

    uuid = :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
    marker = "#{@marker_prefix}#{uuid}"
    marker_regex = ~r/#{Regex.escape(marker)}_(\d+)__/

    # Subscribe to pane output
    pubsub_topic = "pane:#{target}"
    Phoenix.PubSub.subscribe(Termigate.PubSub, pubsub_topic)

    # Send the command with marker
    wrapped = "#{command}; echo #{marker}_$?__\n"

    case PaneStream.send_keys(target, wrapped) do
      :ok ->
        result = collect_output(target, marker_regex, timeout, [])

        Phoenix.PubSub.unsubscribe(Termigate.PubSub, pubsub_topic)

        case result do
          {:ok, output, exit_code} ->
            output = clean_output(output, command, marker, raw)
            {:ok, %{output: output, exit_code: exit_code, timed_out: false}}

          :timeout ->
            # Return partial output on timeout
            {:ok, %{output: "", exit_code: nil, timed_out: true}}
        end

      {:error, reason} ->
        Phoenix.PubSub.unsubscribe(Termigate.PubSub, pubsub_topic)
        {:error, reason}
    end
  end

  defp collect_output(target, marker_regex, timeout, acc) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_collect(target, marker_regex, deadline, acc)
  end

  defp do_collect(target, marker_regex, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      receive do
        {:pane_output, ^target, data} ->
          new_acc = acc ++ [data]
          combined = IO.iodata_to_binary(new_acc)

          case Regex.run(marker_regex, combined) do
            [full_match, exit_code_str] ->
              {exit_code, _} = Integer.parse(exit_code_str)
              output = String.split(combined, full_match) |> List.first() || ""
              {:ok, output, exit_code}

            _ ->
              do_collect(target, marker_regex, deadline, new_acc)
          end

        {:pane_dead, ^target} ->
          {:error, :pane_dead}
      after
        min(remaining, 100) ->
          do_collect(target, marker_regex, deadline, acc)
      end
    end
  end

  defp clean_output(output, command, _marker, raw) do
    output =
      output
      |> String.split("\n")
      # Strip the echoed command line (first line typically)
      |> Enum.reject(fn line ->
        stripped = String.trim(line)
        stripped == "" or String.contains?(stripped, command |> String.slice(0, 40))
      end)
      |> Enum.join("\n")
      |> String.trim()

    if raw, do: output, else: AnsiStripper.strip(output)
  end
end
