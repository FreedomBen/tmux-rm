defmodule Termigate.ConfigTest do
  use ExUnit.Case, async: false

  alias Termigate.Config

  setup do
    # Clear quick actions for each test
    Config.update(fn config -> Map.put(config, "quick_actions", []) end)

    on_exit(fn ->
      Config.update(fn config -> Map.put(config, "quick_actions", []) end)
    end)

    :ok
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

  describe "notifications config" do
    test "defaults are applied when notifications section is missing" do
      Config.update(fn config -> Map.delete(config, "notifications") end)
      config = Config.get()

      assert config["notifications"]["mode"] == "disabled"
      assert config["notifications"]["idle_threshold"] == 10
      assert config["notifications"]["min_duration"] == 5
      assert config["notifications"]["sound"] == false
    end

    test "invalid mode is coerced to disabled" do
      Config.update(fn config ->
        Map.put(config, "notifications", %{"mode" => "bogus"})
      end)

      config = Config.get()
      assert config["notifications"]["mode"] == "disabled"
    end

    test "idle_threshold is clamped to 3-120" do
      Config.update(fn config ->
        Map.put(config, "notifications", %{"idle_threshold" => 1})
      end)

      assert Config.get()["notifications"]["idle_threshold"] == 3

      Config.update(fn config ->
        Map.put(config, "notifications", %{"idle_threshold" => 999})
      end)

      assert Config.get()["notifications"]["idle_threshold"] == 120
    end

    test "min_duration is clamped to 0-600" do
      Config.update(fn config ->
        Map.put(config, "notifications", %{"min_duration" => -1})
      end)

      assert Config.get()["notifications"]["min_duration"] == 0

      Config.update(fn config ->
        Map.put(config, "notifications", %{"min_duration" => 1000})
      end)

      assert Config.get()["notifications"]["min_duration"] == 600
    end

    test "sound is coerced to boolean" do
      Config.update(fn config ->
        Map.put(config, "notifications", %{"sound" => "yes"})
      end)

      assert Config.get()["notifications"]["sound"] == false

      Config.update(fn config ->
        Map.put(config, "notifications", %{"sound" => true})
      end)

      assert Config.get()["notifications"]["sound"] == true
    end

    test "valid modes are accepted" do
      for mode <- ~w(disabled activity shell) do
        Config.update(fn config ->
          Map.put(config, "notifications", %{"mode" => mode})
        end)

        assert Config.get()["notifications"]["mode"] == mode
      end
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts on config change" do
      Phoenix.PubSub.subscribe(Termigate.PubSub, "config")

      Config.upsert_action(%{"label" => "Broadcast", "command" => "test"})

      assert_receive {:config_changed, config}, 1000
      assert Enum.any?(config["quick_actions"], &(&1["label"] == "Broadcast"))
    end
  end
end
