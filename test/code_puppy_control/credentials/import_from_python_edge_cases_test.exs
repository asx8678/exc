defmodule CodePuppyControl.Credentials.ImportFromPythonEdgeCasesTest do
  @moduledoc """
  Edge-case tests for `CodePuppyControl.Credentials.import_from_python/1`
  that complement the existing coverage in `CredentialsTest`.

  New ground covered here:
    * Idempotency across repeated imports
    * Imports preserve unrelated pre-existing store entries
    * Tolerates comment-like lines and section headers in puppy.cfg
    * All 14 recognised API key names round-trip
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Credentials

  setup do
    tmp =
      Path.join([
        System.tmp_dir!(),
        "cp_import_edges_#{:erlang.unique_integer([:positive, :monotonic])}"
      ])

    File.mkdir_p!(tmp)
    store_dir = Path.join(tmp, "store")
    cfg_path = Path.join(tmp, "puppy.cfg")

    # Isolate machine secret so we never touch ~/.code_puppy_ex/.machine_secret
    secret_path = Path.join(tmp, ".machine_secret")
    prev_env = System.get_env("PUP_MACHINE_SECRET_PATH")
    System.put_env("PUP_MACHINE_SECRET_PATH", secret_path)

    on_exit(fn ->
      File.rm_rf!(tmp)

      case prev_env do
        nil -> System.delete_env("PUP_MACHINE_SECRET_PATH")
        v -> System.put_env("PUP_MACHINE_SECRET_PATH", v)
      end
    end)

    {:ok, tmp: tmp, store_dir: store_dir, cfg_path: cfg_path}
  end

  test "is idempotent across repeated imports", ctx do
    File.write!(ctx.cfg_path, "OPENAI_API_KEY=once\n")

    assert {:ok, 1} =
             Credentials.import_from_python(
               python_cfg_path: ctx.cfg_path,
               store_dir: ctx.store_dir
             )

    # Second invocation: same file, same key — still counts as 1 import,
    # and the stored value is unchanged.
    assert {:ok, 1} =
             Credentials.import_from_python(
               python_cfg_path: ctx.cfg_path,
               store_dir: ctx.store_dir
             )

    assert {:ok, "once"} = Credentials.get("OPENAI_API_KEY", store_dir: ctx.store_dir)
  end

  test "preserves unrelated pre-existing store entries", ctx do
    # Populate the store with a key the import logic does NOT know about.
    :ok = Credentials.set("MY_CUSTOM_TOKEN", "preserve-me", store_dir: ctx.store_dir)

    File.write!(ctx.cfg_path, "OPENAI_API_KEY=imported-value\n")

    assert {:ok, 1} =
             Credentials.import_from_python(
               python_cfg_path: ctx.cfg_path,
               store_dir: ctx.store_dir
             )

    # The pre-existing entry must survive.
    assert {:ok, "preserve-me"} =
             Credentials.get("MY_CUSTOM_TOKEN", store_dir: ctx.store_dir)

    # The imported one is now also there.
    assert {:ok, "imported-value"} =
             Credentials.get("OPENAI_API_KEY", store_dir: ctx.store_dir)
  end

  test "tolerates comment-like lines and section headers", ctx do
    # The import regex only matches `^KEY=value` lines, so comments and
    # section headers must NOT break parsing or cause false matches.
    File.write!(ctx.cfg_path, """

    # This is a comment
    OPENAI_API_KEY=sk-abc
    ; semicolon comment
    [section]
    ANTHROPIC_API_KEY=sk-ant

    """)

    assert {:ok, 2} =
             Credentials.import_from_python(
               python_cfg_path: ctx.cfg_path,
               store_dir: ctx.store_dir
             )

    assert {:ok, "sk-abc"} = Credentials.get("OPENAI_API_KEY", store_dir: ctx.store_dir)
    assert {:ok, "sk-ant"} = Credentials.get("ANTHROPIC_API_KEY", store_dir: ctx.store_dir)
  end

  test "imports all 14 recognised API key names when present", ctx do
    known = [
      "OPENAI_API_KEY",
      "GEMINI_API_KEY",
      "ANTHROPIC_API_KEY",
      "CEREBRAS_API_KEY",
      "SYN_API_KEY",
      "AZURE_OPENAI_API_KEY",
      "AZURE_OPENAI_ENDPOINT",
      "OPENROUTER_API_KEY",
      "ZAI_API_KEY",
      "FIREWORKS_API_KEY",
      "GROQ_API_KEY",
      "MISTRAL_API_KEY",
      "MOONSHOT_API_KEY",
      "GITHUB_TOKEN"
    ]

    contents =
      known
      |> Enum.map(fn k -> "#{k}=value-for-#{k}" end)
      |> Enum.join("\n")

    File.write!(ctx.cfg_path, contents <> "\n")

    assert {:ok, 14} =
             Credentials.import_from_python(
               python_cfg_path: ctx.cfg_path,
               store_dir: ctx.store_dir
             )

    for k <- known do
      expected = "value-for-" <> k
      assert {:ok, ^expected} = Credentials.get(k, store_dir: ctx.store_dir)
    end
  end
end
