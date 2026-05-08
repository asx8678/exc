defmodule CodePuppyControl.Config.RoundTripPropertyTest do
  @moduledoc """
  Property-based round-trip tests for config serialization.

  Uses StreamData to verify that Loader and canonical_json are stable
  under re-serialization. These complement the golden-file tests by
  exploring a wider input space.

  Generators deepened in to cover nested structures, UTF-8
  (incl. RTL), and numeric edge cases.

  **How to run:**
      mix test --only config_compat
      # or specifically:
      mix test --only property
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :config_compat
  @moduletag :property

  alias CodePuppyControl.Support.ConfigFixtures
  alias CodePuppyControl.Config.Loader

  # ── Local INI Serializer ─────────────────────────────────────────────────
  # Writer's INI serializer is private (encapsulated in the GenServer), so we
  # provide a deterministic equivalent here for property testing. This mirrors
  # the Writer's output format: sorted sections, sorted keys within sections.

  defp serialize_ini(config) do
    config
    |> Enum.sort_by(fn {section, _} -> section end)
    |> Enum.map_join("\n\n", fn {section, kvs} ->
      header = "[#{section}]"

      lines =
        kvs
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_join("\n", fn {k, v} -> "#{k} = #{v}" end)

      header <> "\n" <> lines
    end)
  end

  # ── Shared Generator ─────────────────────────────────────────────────────

  defp map_of_scalars_gen do
    StreamData.map_of(
      StreamData.string(:ascii, min_length: 1, max_length: 8),
      StreamData.one_of([
        StreamData.string(:ascii),
        StreamData.integer(),
        StreamData.boolean(),
        StreamData.constant(nil)
      ]),
      max_length: 6
    )
  end

  ################################################################################
  # Deepened generators
  ################################################################################

  # Binary-key generator: only string keys (canonical_json requirement).
  # Mix ASCII + UTF-8 to exercise unicode key handling.
  defp string_key_gen do
    StreamData.one_of([
      StreamData.string(:ascii, min_length: 1, max_length: 8),
      StreamData.string(:utf8, min_length: 1, max_length: 8)
    ])
  end

  # UTF-8-aware string generator covering ASCII, multi-byte, and RTL.
  # `StreamData.string(:utf8, ...)` already covers multi-byte codepoints;
  # the explicit exemplars below make RTL/CJK/emoji cases likely to be exercised.
  defp utf8_string_gen do
    StreamData.one_of([
      StreamData.string(:ascii, max_length: 16),
      StreamData.string(:utf8, max_length: 16),
      StreamData.member_of([
        # Hebrew (RTL)
        "שלום",
        # Arabic (RTL)
        "مرحبا",
        # CJK (multi-byte)
        "日本語",
        # emoji + ASCII mix
        "🐶 puppy",
        # empty string edge case
        ""
      ])
    ])
  end

  # Numeric edge cases: 0, negatives, very large ints, finite floats.
  # Floats kept bounded so Jason.encode! never raises on NaN/Infinity.
  defp numeric_gen do
    StreamData.one_of([
      StreamData.constant(0),
      StreamData.constant(-1),
      StreamData.integer(-1_000_000..1_000_000),
      StreamData.member_of([
        # 2^53 (JSON safe-int boundary)
        9_007_199_254_740_992,
        -9_007_199_254_740_992,
        # large positive
        1_000_000_000_000_000
      ]),
      StreamData.float(min: -1.0e6, max: 1.0e6)
    ])
  end

  # Scalar leaf for any nested tree.
  defp scalar_gen do
    StreamData.one_of([
      utf8_string_gen(),
      numeric_gen(),
      StreamData.boolean(),
      StreamData.constant(nil)
    ])
  end

  # Recursive nested map/list tree via StreamData.tree.
  # Shape is bounded by StreamData's generation size, and tree/2 shrinks
  # toward shallower terms. `max_length: 4` keeps each level manageable.
  defp nested_term_gen do
    StreamData.tree(scalar_gen(), fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 4),
        StreamData.map_of(string_key_gen(), child, max_length: 4)
      ])
    end)
  end

  # Top-level term for canonical_json/normalize properties: must be a map
  # (since the production code paths consume map roots).
  defp nested_map_gen do
    StreamData.map_of(string_key_gen(), nested_term_gen(), max_length: 6)
  end

  # ===========================================================================
  # INI Round-Trip
  # ===========================================================================

  describe "INI round-trip stability" do
    property "parse(serialize(parse(fixture))) == parse(fixture)" do
      # Pick one of the two real INI fixtures at random
      check all(
              variant <- StreamData.member_of([:minimal, :realistic]),
              max_runs: 20
            ) do
        raw = ConfigFixtures.read_raw(variant, "puppy.cfg")
        parsed = Loader.parse_string(raw)
        reserialized = serialize_ini(parsed)
        reparsed = Loader.parse_string(reserialized)

        assert ConfigFixtures.normalize(reparsed) == ConfigFixtures.normalize(parsed),
               "INI round-trip diverged for #{variant} fixture"
      end
    end
  end

  # ===========================================================================
  # JSON Canonical Serialization
  # ===========================================================================

  describe "canonical_json idempotency" do
    property "canonical_json is idempotent (nested + utf8 + numeric edges)" do
      check all(m <- nested_map_gen(), max_runs: 100) do
        once = ConfigFixtures.canonical_json(m)
        twice = ConfigFixtures.canonical_json(Jason.decode!(once))
        assert once == twice
      end
    end

    property "canonical_json is idempotent (flat scalars)" do
      check all(m <- map_of_scalars_gen(), max_runs: 50) do
        once = ConfigFixtures.canonical_json(m)
        twice = ConfigFixtures.canonical_json(Jason.decode!(once))
        assert once == twice
      end
    end

    # Deterministic RTL/multi-byte coverage (explicit gate).
    # Uses member_of for BOTH key and value, so every run exercises at least
    # one RTL or multi-byte codepoint in both positions.
    property "canonical_json is idempotent for explicit RTL/multi-byte keys and values" do
      check all(
              key <- StreamData.member_of(["שלום", "مرحبا", "日本語", "🐶"]),
              value <-
                StreamData.member_of([
                  "שלום",
                  "مرحبا",
                  "日本語",
                  "🐶 puppy",
                  ""
                ]),
              max_runs: 20
            ) do
        m = %{key => value}
        once = ConfigFixtures.canonical_json(m)
        twice = ConfigFixtures.canonical_json(Jason.decode!(once))
        assert once == twice
      end
    end
  end

  # ===========================================================================
  # Normalize Idempotency
  # ===========================================================================

  describe "normalize idempotency" do
    property "normalize is idempotent (nested + utf8 + numeric edges)" do
      check all(m <- nested_map_gen(), max_runs: 100) do
        once = ConfigFixtures.normalize(m)
        twice = m |> ConfigFixtures.normalize() |> ConfigFixtures.normalize()
        assert once == twice
      end
    end

    property "normalize is idempotent (flat scalars)" do
      check all(m <- map_of_scalars_gen(), max_runs: 50) do
        once = ConfigFixtures.normalize(m)
        twice = m |> ConfigFixtures.normalize() |> ConfigFixtures.normalize()
        assert once == twice
      end
    end
  end
end
