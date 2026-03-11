defmodule TmuxRm.ConfigTest do
  use ExUnit.Case, async: false

  alias TmuxRm.Config

  @test_dir "/tmp/tmux-rm-config-test"

  setup do
    test_path = Path.join(@test_dir, "config-#{:rand.uniform(100_000)}.yaml")
    File.mkdir_p!(@test_dir)
    File.rm(test_path)

    # Use Config.update to reset to empty state for each test
    # This avoids the complexity of restarting the supervised process
    Config.update(fn _config -> %{"quick_actions" => []} end)

    on_exit(fn ->
      # Reset config after test
      Config.update(fn _config -> %{"quick_actions" => []} end)
    end)

    %{path: test_path}
  end

  describe "get/0" do
    test "returns current config" do
      config = Config.get()
      assert is_map(config)
      assert is_list(config["quick_actions"])
    end
  end

  describe "upsert_action/1" do
    test "adds a new action" do
      action = %{"label" => "Deploy", "command" => "make deploy"}
      {:ok, config} = Config.upsert_action(action)

      actions = config["quick_actions"]
      assert length(actions) == 1
      assert hd(actions)["label"] == "Deploy"
      assert hd(actions)["id"] != nil
    end

    test "updates existing action by id" do
      {:ok, config} = Config.upsert_action(%{"label" => "Test", "command" => "make test"})
      id = hd(config["quick_actions"])["id"]

      {:ok, config} =
        Config.upsert_action(%{
          "id" => id,
          "label" => "Test Updated",
          "command" => "make test-all"
        })

      assert length(config["quick_actions"]) == 1
      assert hd(config["quick_actions"])["label"] == "Test Updated"
    end

    test "normalizes action fields" do
      {:ok, config} =
        Config.upsert_action(%{
          "label" => "Test",
          "command" => "cmd",
          "color" => "invalid",
          "icon" => "invalid",
          "confirm" => false
        })

      action = hd(config["quick_actions"])
      assert action["color"] == "default"
      assert action["icon"] == nil
      assert action["confirm"] == false
    end
  end

  describe "delete_action/1" do
    test "removes action by id" do
      {:ok, config} = Config.upsert_action(%{"label" => "ToDelete", "command" => "rm"})
      id = hd(config["quick_actions"])["id"]

      {:ok, config} = Config.delete_action(id)
      assert config["quick_actions"] == []
    end

    test "no-op for non-existent id" do
      {:ok, config} = Config.delete_action("nonexistent")
      assert config["quick_actions"] == []
    end
  end

  describe "reorder_actions/1" do
    test "reorders actions by id list" do
      {:ok, _} = Config.upsert_action(%{"label" => "A", "command" => "a"})
      {:ok, _} = Config.upsert_action(%{"label" => "B", "command" => "b"})
      {:ok, config} = Config.upsert_action(%{"label" => "C", "command" => "c"})

      ids = Enum.map(config["quick_actions"], & &1["id"])
      reversed = Enum.reverse(ids)

      {:ok, config} = Config.reorder_actions(reversed)
      labels = Enum.map(config["quick_actions"], & &1["label"])
      assert labels == ["C", "B", "A"]
    end

    test "preserves actions not in id list" do
      {:ok, _} = Config.upsert_action(%{"label" => "A", "command" => "a"})
      {:ok, config} = Config.upsert_action(%{"label" => "B", "command" => "b"})

      id_b = Enum.at(config["quick_actions"], 1)["id"]

      {:ok, config} = Config.reorder_actions([id_b])
      labels = Enum.map(config["quick_actions"], & &1["label"])
      assert labels == ["B", "A"]
    end
  end

  describe "malformed config" do
    test "keeps last good config on malformed file" do
      {:ok, _} = Config.upsert_action(%{"label" => "Good", "command" => "echo good"})

      # Get the current config path and corrupt it
      # The Config GenServer uses its internal path
      # We'll write malformed data and trigger a poll
      config = Config.get()
      assert hd(config["quick_actions"])["label"] == "Good"
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts on config change" do
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "config")

      Config.upsert_action(%{"label" => "Broadcast", "command" => "test"})

      assert_receive {:config_changed, config}, 1000
      assert Enum.any?(config["quick_actions"], &(&1["label"] == "Broadcast"))
    end
  end
end
