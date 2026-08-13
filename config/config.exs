# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ctf_server, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [provision: 5, deprovision: 5],
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"* * * * *", CtfServer.Workers.CompetitionSweeper}]}
  ],
  repo: CtfServer.Repo

config :ctf_server,
  ecto_repos: [CtfServer.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true],
  # When true, newly registered teams are confirmed immediately and no
  # confirmation email is sent. Override at runtime with
  # CTF_SERVER_SKIP_ACCOUNT_CONFIRMATION (see config/runtime.exs).
  skip_account_confirmation: true,
  # Host ports handed out for challenge VM SSH forwarding, one per running VM.
  # A generous default in the IANA dynamic range so the pool does not exhaust
  # under load (exhaustion is handled gracefully, but should stay rare). Deploys
  # override at runtime with CTF_SERVER_VM_PORT_RANGE (see config/runtime.exs).
  vm_port_range: 49_152..50_175,
  # Most running VMs a single team may hold at once (guards against a team
  # exhausting host CPU/RAM). Counts attempts whose VM is up
  # (:provisioning/:started); paused instances don't count. Admin teams are
  # exempt. Override at runtime with CTF_SERVER_MAX_VMS_PER_TEAM.
  max_vms_per_team: 8,
  vm_base_image_path: Path.expand("../priv/vm_bases", __DIR__),
  vm_overlay_path: Path.expand("../priv/vm_bases/overlays", __DIR__),
  vm_libvirt_uri: "qemu:///system",
  vm_ssh_host: "localhost"

# Configures the endpoint
config :ctf_server, CtfServerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CtfServerWeb.ErrorHTML, json: CtfServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CtfServer.PubSub,
  live_view: [signing_salt: "cWUTKZa4"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ctf_server, CtfServer.Mailer, adapter: Swoosh.Adapters.Local

config :ctf_server, :require_invite_codes, false
config :ctf_server, :local_networks, []

# Whether auth cookies (session + remember-me) carry the `Secure` flag, so the
# browser only sends them over HTTPS (CWE-614). Off here for dev/test over
# plaintext HTTP; prod.exs turns it on.
config :ctf_server, :secure_cookies, false

# Rate limits for the unauthenticated auth endpoints, as {max_hits, window_ms}
# per client IP. Guards against password brute-forcing and the Argon2 CPU cost
# of each attempt (CWE-307). See CtfServer.RateLimiter.
config :ctf_server, :rate_limits,
  login: {10, 60_000},
  register: {5, 60_000},
  password_reset: {5, 60_000}

# Configure esbuild (the version is required)
config :esbuild,
  path: System.get_env("MIX_ESBUILD_PATH"),
  version: System.get_env("MIX_ESBUILD_VERSION"),
  ctf_server: [
    # js/vega.js is a second entry point, not part of the app bundle: the Vega
    # runtime is ~812KB and only the leaderboard charts, so the VegaChart hook
    # loads /assets/vega.js on demand. The --alias flags point Vega's UMD builds
    # at the vendored copies (there is no npm install in this project); keep them
    # in sync with the esbuild call in nix/package.nix.
    args:
      ~w(js/app.js js/vega.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --alias:vega=./vendor/vega.min.js --alias:vega-lite=./vendor/vega-lite.min.js --alias:vega-embed=./vendor/vega-embed.min.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  path: System.get_env("MIX_TAILWIND_PATH"),
  version: System.get_env("MIX_TAILWIND_VERSION"),
  ctf_server: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Password-hashing cost, pinned explicitly rather than inherited from
# argon2_elixir's defaults — those changed in its 4.0 release (t_cost 8 -> 3,
# parallelism 2 -> 4), which would otherwise have silently halved the work
# factor on this app's hashes, from ~208ms to ~97ms per hash on the dev box.
# These are the values the deployed hashes were created with, so the upgrade is
# a no-op for auth. Raising t_cost strengthens hashing but also raises the cost
# of the CPU-exhaustion vector that `CtfServerWeb.Plugs.RateLimitAuth` bounds;
# change the two together. Existing hashes carry their own parameters in the
# encoded string, so they keep verifying regardless of what is set here.
# `config/test.exs` overrides these downward to keep the suite fast.
config :argon2_elixir, t_cost: 8, m_cost: 16, parallelism: 2

# Redact sensitive request parameters from the Phoenix request logger, which
# otherwise logs POST bodies verbatim (e.g. the team log-in password). Matching
# is substring-based, so "password" also covers "current_password" and
# "password_confirmation". "invite_code" keeps one-time codes out of the logs.
#
# Defined once and applied to both keys on purpose. Phoenix compiles its own
# copy at boot into an opaque matcher tuple, so `:phoenix, :filter_parameters`
# cannot be read back as a list at runtime — `CtfServer.LogRedactor`, which
# scrubs the same tokens out of crash reports, reads the `:ctf_server` copy.
filtered_parameters = ["password", "invite_code"]

config :phoenix, :filter_parameters, filtered_parameters
config :ctf_server, :filter_parameters, filtered_parameters

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
