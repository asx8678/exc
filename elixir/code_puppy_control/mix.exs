defmodule CodePuppyControl.MixProject do
  use Mix.Project

  def project do
    [
      app: :code_puppy_control,
      # Elixir/native release stream. Python/PyPI compatibility stream lives in
      # ../../pyproject.toml and is intentionally independent during migration.
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      compilers: [:leex, :yecc] ++ Mix.compilers(),
      escript: escript(),
      releases: releases(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp escript do
    [
      main_module: CodePuppyControl.CLI,
      # Native daily-driver command. This collides with the Python `codepp`
      # legacy `pup` console script, so docs must call out PATH ambiguity.
      # Do not rename without a release/deprecation plan; CI/package smoke
      # currently validate `./pup`.
      name: :pup,
      # Bundle priv files from :code_puppy_control so models.json and
      # models_dev_api.json are available in the escript archive.
      # NOTE: NIF .so files (exqlite) still cannot be loaded from the
      # zip archive — the Application detects escript mode and skips
      # DB-dependent children (Repo, Oban, Endpoint). (code-puppy-be7)
      app: :code_puppy_control
    ]
  end

  def application do
    base_apps =
      [
        :kernel,
        :stdlib,
        :elixir,
        :logger,
        :runtime_tools,
        :phoenix,
        :phoenix_ecto,
        :phoenix_pubsub,
        :phoenix_live_view,
        :phoenix_html,
        :jason,
        :oban,
        :crontab,
        :plug_cowboy,
        :telemetry,
        :msgpax,
        :finch,
        :xxhash,
        :owl
      ]

    # In prod (Burrito/release) mode, the exqlite NIF is available so
    # DB-dependent apps auto-start. In dev/escript mode, the NIF cannot
    # load from the zip archive, so these apps must be included-only
    # (loaded but not auto-started); Application.build_children/1 calls
    # Application.ensure_all_started(:ecto_sqlite3) lazily when needed.
    #
    # (code-puppy-be7) If ecto_sqlite3/exqlite appear in both applications
    # and included_applications, Mix raises at compile time — hence the
    # env-conditional split.
    {db_apps, db_included} =
      if Mix.env() == :prod do
        # Burrito/release: NIF is available, auto-start DB apps.
        # oban already in base_apps; ecto_sqlite3 brings its own deps.
        {[:ecto_sqlite3, :exqlite, :db_connection, :ecto_sql, :ecto], []}
      else
        # Dev/escript: NIF unavailable, include-only until explicitly
        # started by Application.build_children/1.
        {[], [:ecto_sqlite3, :exqlite, :db_connection, :ecto_sql, :ecto]}
      end

    # erlexec is always included-only (loaded, not auto-started).
    # PtyManager lazily calls Application.ensure_all_started(:erlexec)
    # on first PTY session; ExecutorPty falls back to System.cmd if
    # erlexec is unavailable.
    #
    # burrito is listed as included_applications so its beam files are
    # on the code path during `mix release` step execution (the
    # &Burrito.wrap/1 step needs the module loaded). It has no `mod`
    # callback so it won't auto-start.
    included = [:erlexec, :burrito] ++ db_included

    [
      mod: {CodePuppyControl.Application, []},
      applications: base_apps ++ db_apps,
      included_applications: included
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_pubsub, "~> 2.1"},
      # LiveView admin UI (code_puppy-yge.3) — optional surface, never owns runtime state.
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:jason, "~> 1.4"},
      {:oban, "~> 2.17"},
      {:crontab, "~> 1.1"},
      {:plug_cowboy, "~> 2.7"},
      {:ecto_sqlite3, "~> 0.13"},
      {:stream_data, "~> 1.0", only: :test},
      {:telemetry, "~> 1.2"},
      {:benchee, "~> 1.1", only: :dev, runtime: false},
      {:benchee_markdown, "~> 0.3", only: :dev, runtime: false},
      # MessagePack for session serialization
      {:msgpax, "~> 2.4"},
      # HTTP client with connection pooling
      {:finch, "~> 0.18"},
      # xxhash for pure Elixir HashLine implementation
      {:xxhash, "~> 0.3"},
      # OS process management with PTY support
      {:erlexec, "~> 2.0"},
      # TUI rendering with Owl
      {:owl, "~> 0.11"},
      # Burrito single-binary packaging
      {:burrito, "~> 1.3", runtime: false}
    ]
  end

  defp releases do
    [
      code_puppy_control: [
        steps: [:assemble, &Burrito.wrap/1],
        vm_args: "rel/overlays/vm.args.eex",
        include_erts: true,
        strip_beams: true,
        burrito: [
          extra_steps: [
            build: [pre: [CodePuppyControl.BurritoSteps.PatchMuslQualifier]]
          ],
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            linux_musl_x86_64: [os: :linux, cpu: :x86_64, musl: true],
            linux_musl_arm64: [os: :linux, cpu: :aarch64, musl: true],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "gates.isolation": ["test test/code_puppy_control/config/isolation_gates_test.exs"]
    ]
  end
end
