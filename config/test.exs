import Config
config :ctf_server, Oban, testing: :manual

# The scoreboard cache is a long-lived process that queries on its own, which
# no test's sandbox connection owns. Off here; callers compute inline instead
# and get identical results. See `CtfServer.ScoreboardCache`.
config :ctf_server, start_scoreboard_cache: false

# Only in tests, remove the complexity from the password hashing algorithm
config :argon2_elixir, t_cost: 1, m_cost: 8

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ctf_server, CtfServer.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ctf_server_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ctf_server, CtfServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "4Jeebv2e6GaO6Tdd6CG1jENtVMHhduUqENUGWa4jGPkMoPOJG45so3hTScFkI/TL",
  server: false

# In test we don't send emails
config :ctf_server, CtfServer.Mailer, adapter: Swoosh.Adapters.Test

# Effectively disable auth rate limiting for the suite at large: the whole run
# hits these endpoints from 127.0.0.1 inside one window. The rate-limiter tests
# opt back into small limits on a distinct IP so they stay isolated.
config :ctf_server, :rate_limits,
  login: {1_000_000, 60_000},
  register: {1_000_000, 60_000},
  password_reset: {1_000_000, 60_000}

# Exercise the full email confirmation flow in tests; the skip behaviour is
# tested explicitly by toggling this setting.
config :ctf_server, :skip_account_confirmation, false

# Write audit events inline so tests can observe them; production uses
# fire-and-forget tasks.
config :ctf_server, CtfServer.Audit, sync: true

# Never let the suite read or destroy the developer's real libvirt state.
config :ctf_server, :vm_backend, CtfServer.StubVMBackend

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
