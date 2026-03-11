defmodule TmuxRm.Tmux.CommandRunner do
  @moduledoc "Runs tmux commands via System.cmd."
  @behaviour TmuxRm.Tmux.CommandRunnerBehaviour

  require Logger

  @impl true
  def run(args) do
    tmux_path = tmux_executable()
    full_args = socket_args() ++ args

    Logger.debug("tmux command: #{tmux_path} #{Enum.join(full_args, " ")}")

    case System.cmd(tmux_path, full_args, stderr_to_stdout: true) do
      {stdout, 0} ->
        check_version_once()
        {:ok, String.trim(stdout)}

      {stdout, code} ->
        Logger.debug("tmux command failed (exit #{code}): #{stdout}")
        {:error, {String.trim(stdout), code}}
    end
  end

  @impl true
  def run!(args) do
    case run(args) do
      {:ok, stdout} -> stdout
      {:error, {stderr, code}} -> raise "tmux command failed (exit #{code}): #{stderr}"
    end
  end

  defp tmux_executable do
    case Application.get_env(:tmux_rm, :tmux_path) do
      nil -> "tmux"
      path -> path
    end
  end

  defp socket_args do
    case Application.get_env(:tmux_rm, :tmux_socket) do
      nil -> []
      socket -> ["-S", socket]
    end
  end

  defp check_version_once do
    unless :persistent_term.get(:tmux_version_checked, false) do
      :persistent_term.put(:tmux_version_checked, true)

      case System.cmd(tmux_executable(), ["-V"], stderr_to_stdout: true) do
        {version_str, 0} ->
          version = String.trim(version_str)
          Logger.info("tmux version: #{version}")

          case parse_version(version) do
            {major, minor} when major > 3 or (major == 3 and minor >= 1) ->
              :ok

            {major, minor} ->
              Logger.warning("tmux version #{major}.#{minor} detected, minimum required is 3.1")

            :error ->
              Logger.warning("Could not parse tmux version: #{version}")
          end

        _ ->
          :ok
      end
    end
  end

  defp parse_version(version_str) do
    case Regex.run(~r/(\d+)\.(\d+)/, version_str) do
      [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)}
      _ -> :error
    end
  end
end
