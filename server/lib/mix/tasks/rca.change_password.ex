defmodule Mix.Tasks.Rca.ChangePassword do
  @moduledoc "Change the password for tmux-rm."
  @shortdoc "Change tmux-rm password"

  use Mix.Task

  @impl true
  def run(_args) do
    case TmuxRm.Auth.read_credentials() do
      {:ok, {username, _hash}} ->
        current = Mix.shell().prompt("Current password: ") |> String.trim()

        case TmuxRm.Auth.verify_credentials(username, current) do
          :ok ->
            new_password = Mix.shell().prompt("New password: ") |> String.trim()

            if new_password == "" do
              Mix.shell().error("Password cannot be empty.")
              exit({:shutdown, 1})
            end

            confirm = Mix.shell().prompt("Confirm new password: ") |> String.trim()

            if new_password != confirm do
              Mix.shell().error("Passwords do not match.")
              exit({:shutdown, 1})
            end

            case TmuxRm.Auth.write_credentials(username, new_password) do
              :ok -> Mix.shell().info("Password changed successfully.")
              {:error, reason} -> Mix.shell().error("Failed: #{inspect(reason)}")
            end

          :error ->
            Mix.shell().error("Current password is incorrect.")
            exit({:shutdown, 1})
        end

      {:error, :not_found} ->
        Mix.shell().error("No credentials found. Run `mix rca.setup` first.")
        exit({:shutdown, 1})
    end
  end
end
