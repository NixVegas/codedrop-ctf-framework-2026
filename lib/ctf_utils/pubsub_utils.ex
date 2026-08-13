defmodule CtfUtils.PubSubUtils do
  @moduledoc """
  Helpers to keep pubsub in one place.

  Attempt updates are published on a per-team topic (`team:<team_id>`)
  rather than per-attempt, so a subscriber can follow a team with a single
  subscription and still hear about attempts created after it subscribed.
  Leaderboard-affecting changes are published on a global topic.
  """

  alias CtfServer.ChallengeAttempt
  alias Phoenix.PubSub

  @leaderboard_topic "leaderboard"
  @scoreboard_topic "scoreboard"
  @feed_topic "feed"
  @competition_topic "competition"

  defp team_topic(team_id), do: "team:#{team_id}"

  @doc """
  Broadcasts that one of a team's attempts changed (created, transitioned,
  or deleted). Carries the attempt id; subscribers re-query as needed.
  """
  def pub_attempt_update(%ChallengeAttempt{} = attempt) do
    :ok =
      PubSub.broadcast(
        CtfServer.PubSub,
        team_topic(attempt.team_id),
        {:attempt_updated, attempt.id}
      )

    :ok
  end

  @doc "Subscribes the calling process to a team's attempt updates."
  def sub_team_updates(team_id) do
    :ok = PubSub.subscribe(CtfServer.PubSub, team_topic(team_id))
    :ok
  end

  @doc "Unsubscribes the calling process from a team's attempt updates."
  def unsub_team_updates(team_id) do
    :ok = PubSub.unsubscribe(CtfServer.PubSub, team_topic(team_id))
    :ok
  end

  @doc """
  Broadcasts that the leaderboard changed (an attempt completed or a
  completed attempt was removed).
  """
  def pub_leaderboard_update do
    :ok = PubSub.broadcast(CtfServer.PubSub, @leaderboard_topic, :leaderboard_updated)
    :ok
  end

  @doc "Subscribes the calling process to leaderboard updates."
  def sub_leaderboard do
    :ok = PubSub.subscribe(CtfServer.PubSub, @leaderboard_topic)
    :ok
  end

  @doc """
  Broadcasts that `CtfServer.ScoreboardCache` has recomputed the scoreboard.

  Distinct from `pub_leaderboard_update/0` on purpose: that one fires on every
  capture and is consumed by the cache alone, while this one is the throttled
  signal the LiveViews render from. Keeping them on separate topics means the
  cache never receives an echo of its own broadcast.
  """
  def pub_scoreboard_refresh do
    :ok = PubSub.broadcast(CtfServer.PubSub, @scoreboard_topic, :scoreboard_refreshed)
    :ok
  end

  @doc "Subscribes the calling process to throttled scoreboard recomputations."
  def sub_scoreboard do
    :ok = PubSub.subscribe(CtfServer.PubSub, @scoreboard_topic)
    :ok
  end

  @doc """
  Broadcasts that an audit event the activity feed cares about was recorded.

  Filtered here rather than in every subscriber so that auth, account, and
  admin events — the bulk of the audit log — never reach the feed's topic.
  """
  def pub_feed_activity(topic, event)

  def pub_feed_activity("challenge", event)
      when event in ["start", "complete", "submit_flag_failed"] do
    :ok = PubSub.broadcast(CtfServer.PubSub, @feed_topic, :feed_activity)
    :ok
  end

  def pub_feed_activity(_topic, _event), do: :ok

  @doc "Subscribes the calling process to activity feed events."
  def sub_feed do
    :ok = PubSub.subscribe(CtfServer.PubSub, @feed_topic)
    :ok
  end

  @doc "Broadcasts that the competition window changed."
  def pub_competition do
    :ok = PubSub.broadcast(CtfServer.PubSub, @competition_topic, :competition_refresh)
    :ok
  end

  @doc "Subscribes the calling process to competition window updates."
  def sub_competition do
    :ok = PubSub.subscribe(CtfServer.PubSub, @competition_topic)
    :ok
  end
end
