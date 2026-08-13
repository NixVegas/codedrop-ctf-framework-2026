defmodule CtfServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Scrub secrets from crash reports before anything can crash and log them.
    CtfServer.LogRedactor.install()

    children = [
      CtfServerWeb.Telemetry,
      CtfServer.Repo,
      {DNSCluster, query: Application.get_env(:ctf_server, :dns_cluster_query) || :ignore},
      {Oban, Application.fetch_env!(:ctf_server, Oban)},
      {Phoenix.PubSub, name: CtfServer.PubSub},
      # In-memory rate limiter guarding the auth endpoints
      CtfServer.RateLimiter,
      # Fire-and-forget audit event writes
      {Task.Supervisor, name: CtfServer.Audit.TaskSupervisor},
      # Start the Finch HTTP client for sending emails
      {Finch, name: CtfServer.Finch},
      # Start a worker by calling: CtfServer.Worker.start_link(arg)
      # {CtfServer.Worker, arg},
      # Start to serve requests, typically the last entry
      CtfServerWeb.Endpoint
    ]

    # Computes the scoreboard once per change instead of once per open
    # leaderboard. Off in test, where callers take the equivalent uncached path
    # rather than have a long-lived process query outside the sandbox — see
    # `CtfServer.ScoreboardCache`.
    children =
      if Application.get_env(:ctf_server, :start_scoreboard_cache, true) do
        children ++ [CtfServer.ScoreboardCache]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CtfServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CtfServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
