defmodule CtfServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :ctf_server,
      version: "0.1.0",
      # 1.18 is the floor for the `:listeners` project key below. The Nix build
      # and dev shell both use Elixir 1.19, so this only makes the real
      # requirement explicit rather than failing confusingly on an older one.
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Phoenix 1.8 drives dev code reloading through Mix's listener mechanism
      # (Elixir >= 1.18) rather than compiling in-process. Without this,
      # `Phoenix.CodeReloader` warns on every reload attempt in `mix phx.server`
      # and does not pick up changes. Dev-only in effect; harmless in prod.
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run `mix precommit` in the test environment so its `test` step (and the
  # test-env compile) work — Mix aliases do not switch MIX_ENV on their own.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {CtfServer.Application, []},
      extra_applications: [:logger, :runtime_tools, :observer]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  # Every hex dep is pinned to an exact version (`== x.y.z`) rather than a `~>`
  # range: the event runs on whatever resolved here, and we do not want a
  # `mix deps.get` on a staff box to silently pull a different build mid-event.
  # Bumping is therefore a deliberate edit — run `mix hex.outdated` to see what
  # has moved, and re-hash `nix/package.nix` after any change to `mix.lock`.
  defp deps do
    [
      {:argon2_elixir, "== 4.1.3"},
      {:phoenix, "== 1.8.9"},
      {:phoenix_ecto, "== 4.7.0"},
      {:ecto_sql, "== 3.14.0"},
      {:postgrex, "== 0.22.3"},
      {:phoenix_html, "== 4.3.0"},
      {:phoenix_live_reload, "== 1.7.0", only: :dev},
      {:phoenix_live_view, "== 1.2.8"},
      # LiveView >= 1.1 parses test DOM with LazyHTML, not Floki. Nothing in
      # this repo calls Floki directly, so it is gone rather than pinned.
      {:lazy_html, "== 0.1.12", only: :test},
      {:phoenix_live_dashboard, "== 0.8.7"},
      # Builds the scoreboard chart's Vega-Lite spec server-side. Spec only —
      # the rendering library is vendored JS (assets/vendor/vega*).
      {:vega_lite, "== 0.1.11"},
      {:esbuild, "== 0.10.0", runtime: Mix.env() == :dev},
      {:tailwind, "== 0.5.1", runtime: Mix.env() == :dev},
      # Not on hex — pinned to an exact git tag, which is already reproducible.
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "== 1.27.0"},
      # Req is the HTTP client for application code (`CtfServer.HomeAssistant`).
      # It runs on Finch, which is also Swoosh's mail adapter and is started as
      # a named pool in `CtfServer.Application`, so both share one pool.
      {:req, "== 0.7.2"},
      {:finch, "== 0.23.0"},
      # Optional dep of Mint (which Finch runs on), but it was in the lock
      # before this pass and it is what supplies the CA bundle for outbound
      # HTTPS. Declared explicitly so dropping it is a deliberate act, not a
      # side effect of `mix deps.unlock --unused`.
      {:castore, "== 1.0.20"},
      {:telemetry_metrics, "== 1.1.0"},
      {:telemetry_poller, "== 1.3.0"},
      {:jason, "== 1.4.5"},
      {:dns_cluster, "== 0.2.0"},
      # Past the Bandit websocket/HTTP DoS + request-smuggling advisories
      # (CVE-2026-39803..39806, -42786, -42788). See mix hex.audit.
      {:bandit, "== 1.12.4"},
      {:earmark, "== 1.4.49"},
      {:oban, "== 2.23.1"},
      {:oban_web, "== 2.12.6"},
      {:igniter, "== 0.8.3", only: [:dev]},
      {:temp, "== 0.4.9"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      # Run before every commit; CI-equivalent gate. Keep this green.
      precommit: ["format --check-formatted", "compile --warnings-as-errors", "test"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind ctf_server", "esbuild ctf_server"],
      "assets.deploy": [
        "tailwind ctf_server --minify",
        "esbuild ctf_server --minify",
        "phx.digest"
      ]
    ]
  end
end
