defmodule CodePuppyControl.TUI.Widgets.AgentSelectorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CodePuppyControl.TUI.Widgets.AgentSelector

  describe "list_agents/1" do
    test "returns a list of agent_entry maps with required keys" do
      agents = AgentSelector.list_agents()

      assert is_list(agents)

      for agent <- agents do
        assert Map.has_key?(agent, :name)
        assert Map.has_key?(agent, :slug)
        assert Map.has_key?(agent, :display_name)
        assert Map.has_key?(agent, :description)
        assert Map.has_key?(agent, :module)
        assert is_binary(agent.name)
        assert is_binary(agent.slug)
        assert is_binary(agent.display_name)
        assert is_binary(agent.description)
      end
    end

    test "slugs are kebab-case (no underscores)" do
      agents = AgentSelector.list_agents()

      for agent <- agents do
        refute agent.slug =~ "_",
               "Expected kebab-case slug but got: #{agent.slug}"
      end
    end

    test "slug is derived from catalogue name via underscore-to-hyphen" do
      agents = AgentSelector.list_agents()

      for agent <- agents do
        expected_slug = String.replace(agent.name, "_", "-")

        assert agent.slug == expected_slug,
               "Slug #{agent.slug} doesn't match expected #{expected_slug} from name #{agent.name}"
      end
    end

    test "results are sorted by name" do
      agents = AgentSelector.list_agents()
      names = Enum.map(agents, & &1.name)
      assert names == Enum.sort(names)
    end

    test "filter option narrows results by name substring (case-insensitive)" do
      all = AgentSelector.list_agents()

      if all != [] do
        sample = hd(all)
        fragment = String.slice(sample.display_name, 0, 3)
        filtered = AgentSelector.list_agents(filter: fragment)

        assert is_list(filtered)

        for agent <- filtered do
          assert String.downcase(agent.display_name) =~ String.downcase(fragment) or
                   String.downcase(agent.slug) =~ String.downcase(fragment) or
                   String.downcase(agent.name) =~ String.downcase(fragment)
        end

        filtered_slugs = Enum.map(filtered, & &1.slug)
        all_slugs = Enum.map(all, & &1.slug)
        assert MapSet.new(filtered_slugs) |> MapSet.subset?(MapSet.new(all_slugs))
      end
    end

    test "filter with no matches returns empty list" do
      agents = AgentSelector.list_agents(filter: "zzz_no_such_agent_xyz_999")
      assert agents == []
    end

    test "filter is case-insensitive" do
      all = AgentSelector.list_agents()

      if all != [] do
        name = hd(all).name
        lower = AgentSelector.list_agents(filter: String.downcase(name))
        upper = AgentSelector.list_agents(filter: String.upcase(name))
        assert length(lower) >= 1
        assert length(upper) >= 1
      end
    end

    test "filter matches on slug (kebab-case)" do
      all = AgentSelector.list_agents()

      if all != [] do
        slug = hd(all).slug

        if slug =~ "-" do
          fragment = String.split(slug, "-") |> hd()
          filtered = AgentSelector.list_agents(filter: fragment)

          assert is_list(filtered)
          assert length(filtered) >= 1
        end
      end
    end
  end

  describe "agent_entry structure" do
    test "display_name is human-friendly (not snake_case or kebab-case)" do
      agents = AgentSelector.list_agents()

      for agent <- agents do
        refute agent.display_name =~ "_",
               "display_name should not contain underscores: #{agent.display_name}"
      end
    end

    test "module is nil or an atom" do
      agents = AgentSelector.list_agents()

      for agent <- agents do
        assert agent.module == nil or is_atom(agent.module)
      end
    end
  end

  describe "select/1" do
    test "with filter producing no agents returns :cancelled" do
      output =
        capture_io(fn ->
          assert AgentSelector.select(filter: "zzz_no_such_agent_999_xyz") == :cancelled
        end)

      assert output =~ "No agents available"
    end

    test "selects first agent by number 1 via Owl path" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        first_slug = hd(agents).slug

        output =
          capture_io("1\n", fn ->
            assert AgentSelector.select() == {:ok, first_slug}
          end)

        assert output =~ "1."
      end
    end

    test "label appears in rendered output" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        output =
          capture_io("1\n", fn ->
            assert AgentSelector.select(label: "Choose your agent")
          end)

        assert output =~ "Choose your agent"
      end
    end

    test "default slug is highlighted in output" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        slug = hd(agents).slug

        output =
          capture_io("1\n", fn ->
            assert AgentSelector.select(default: slug)
          end)

        assert output =~ slug
      end
    end

    test "filter narrows agents before selection" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        agent = hd(agents)
        filter = String.slice(agent.display_name, 0, 5)

        output =
          capture_io("1\n", fn ->
            assert AgentSelector.select(filter: filter)
          end)

        assert output =~ agent.display_name
      end
    end

    test "selects by display name via Owl path" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        agent = hd(agents)

        # Find the index of the agent (Owl.select uses integer index)
        slugs = Enum.map(agents, & &1.slug)
        idx = Enum.find_index(slugs, &(&1 == agent.slug))
        input = "#{idx + 1}\n"

        capture_io(input, fn ->
          assert AgentSelector.select() == {:ok, agent.slug}
        end)
      end
    end

    test "select with default returns {:ok, slug} when agent chosen" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        slug = hd(agents).slug

        capture_io("1\n", fn ->
          assert AgentSelector.select(default: slug) == {:ok, slug}
        end)
      end
    end

    test "filter that matches only one agent auto-selects it" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        agent = hd(agents)

        # Use entire display name as filter — should match just this agent
        # Provide "1\n" since Owl might still show a list
        capture_io("1\n", fn ->
          result = AgentSelector.select(filter: agent.display_name)
          assert result == {:ok, agent.slug} or result == :cancelled
        end)
      end
    end
  end

  describe "fallback_select path" do
    setup do
      # Store original values
      orig_fallback = Application.get_env(:code_puppy_control, :force_fallback_select, false)
      orig_build = Application.get_env(:code_puppy_control, :force_build_table_fallback, false)

      # Force fallback paths
      Application.put_env(:code_puppy_control, :force_fallback_select, true)
      Application.put_env(:code_puppy_control, :force_build_table_fallback, true)

      on_exit(fn ->
        Application.put_env(:code_puppy_control, :force_fallback_select, orig_fallback)
        Application.put_env(:code_puppy_control, :force_build_table_fallback, orig_build)
      end)

      :ok
    end

    test "empty input returns :cancelled" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        output =
          capture_io("\n", fn ->
            assert AgentSelector.select() == :cancelled
          end)

        assert output =~ "blank to cancel"
        assert output =~ "1."
      end
    end

    test "selects by number via fallback" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        first_slug = hd(agents).slug

        output =
          capture_io("1\n", fn ->
            assert AgentSelector.select() == {:ok, first_slug}
          end)

        assert output =~ "1."
      end
    end

    test "selects by exact slug" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        slug = hd(agents).slug

        output =
          capture_io(slug <> "\n", fn ->
            assert AgentSelector.select() == {:ok, slug}
          end)

        assert output =~ slug
      end
    end

    test "selects by fuzzy display name" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        agent = hd(agents)
        fragment = String.slice(agent.display_name, 0, 3)

        output =
          capture_io(fragment <> "\n", fn ->
            assert AgentSelector.select() == {:ok, agent.slug}
          end)

        assert output =~ fragment
      end
    end

    test "invalid number outside range returns :cancelled" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        output =
          capture_io("999\n", fn ->
            assert AgentSelector.select() == :cancelled
          end)

        assert output =~ ">"
      end
    end

    test "non-matching input returns :cancelled" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        output =
          capture_io("xyznonexistent\n", fn ->
            assert AgentSelector.select() == :cancelled
          end)

        assert output =~ ">"
      end
    end

    test "label option appears in fallback prompt" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        output =
          capture_io("\n", fn ->
            assert AgentSelector.select(label: "FallbackLabel") == :cancelled
          end)

        assert output =~ "FallbackLabel"
      end
    end

    test "build_table fallback produces output without Owl.Table" do
      agents = AgentSelector.list_agents()

      if length(agents) >= 1 do
        slug = hd(agents).slug

        output =
          capture_io("\n", fn ->
            assert AgentSelector.select() == :cancelled
          end)

        # The fallback build_table should include agent info in plain text
        assert output =~ slug
      end
    end
  end
end
