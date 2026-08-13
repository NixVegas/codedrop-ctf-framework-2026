defmodule CtfServerWeb.Router do
  use CtfServerWeb, :router

  import Oban.Web.Router
  import CtfServerWeb.TeamAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CtfServerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_team
    plug CtfServerWeb.Plugs.ClientLocality
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :rate_limit_login do
    plug CtfServerWeb.Plugs.RateLimitAuth, bucket: :login
  end

  scope "/", CtfServerWeb do
    pipe_through :browser

    get "/", PageController, :home

    live_session :public,
      on_mount: [{CtfServerWeb.TeamAuth, :mount_current_team}] do
      live "/leaderboard", LeaderboardLive, :new
      live "/feed", FeedLive, :public
    end
  end

  # Machine-readable twin of /feed, for anything that would rather poll JSON
  # than hold a websocket open. Public and sanitized — see CtfServer.Feed.
  scope "/api", CtfServerWeb do
    pipe_through :api

    get "/feed", FeedController, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ctf_server, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CtfServerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/" do
      pipe_through :browser

      oban_dashboard("/oban")
    end
  end

  ## Authentication routes
  scope "/", CtfServerWeb do
    pipe_through [:browser, :redirect_if_team_is_authenticated]

    live_session :redirect_if_team_is_authenticated,
      on_mount: [{CtfServerWeb.TeamAuth, :redirect_if_team_is_authenticated}] do
      live "/teams/register", TeamRegistrationLive, :new
      live "/teams/log_in", TeamLoginLive, :new
      live "/teams/reset_password", TeamForgotPasswordLive, :new
      live "/teams/reset_password/:token", TeamResetPasswordLive, :edit
    end
  end

  scope "/", CtfServerWeb do
    pipe_through [:browser, :redirect_if_team_is_authenticated, :rate_limit_login]

    post "/teams/log_in", TeamSessionController, :create
  end

  # Normal user routes
  scope "/", CtfServerWeb do
    pipe_through [:browser, :require_authenticated_team]

    live_session :require_authenticated_team,
      on_mount: [{CtfServerWeb.TeamAuth, :ensure_authenticated}] do
      live "/teams/settings", TeamSettingsLive, :edit
      live "/teams/settings/confirm_email/:token", TeamSettingsLive, :confirm_email

      live "/dashboard", TeamDashboardLive, :index
      live "/challenge/:group/:level", ChallengeLive, :show
    end
  end

  # Admin routes
  scope "/", CtfServerWeb do
    pipe_through [:browser, :require_authenticated_team, :require_admin]

    live_session :require_authenticated_admin,
      on_mount: [{CtfServerWeb.TeamAuth, :ensure_admin}] do
      live "/admin/teams", AdminTeamsLive, :index
      live "/admin/teams/:id", AdminTeamLive, :show
      live "/admin/audit", AdminAuditLive, :index
      live "/admin/feed", FeedLive, :admin
      live "/admin/manual", AdminManualLive, :index
      live "/admin/manual/:slug", AdminManualLive, :show
      live "/admin/vms", AdminVmsLive, :index
      live "/admin/invites", AdminInvitesLive, :index
      live "/admin/competition", AdminCompetitionLive, :index

      live "/challenge_attempt", ChallengeAttemptLive.Index, :index
      live "/challenge_attempt/new", ChallengeAttemptLive.Index, :new
      live "/challenge_attempt/:id/edit", ChallengeAttemptLive.Index, :edit

      live "/challenge_attempt/:id", ChallengeAttemptLive.Show, :show
      live "/challenge_attempt/:id/show/edit", ChallengeAttemptLive.Show, :edit
    end
  end

  # Token and logout routes
  scope "/", CtfServerWeb do
    pipe_through [:browser]

    delete "/teams/log_out", TeamSessionController, :delete

    live_session :current_team,
      on_mount: [{CtfServerWeb.TeamAuth, :mount_current_team}] do
      live "/teams/confirm/:token", TeamConfirmationLive, :edit
      live "/teams/confirm", TeamConfirmationInstructionsLive, :new
    end
  end
end
