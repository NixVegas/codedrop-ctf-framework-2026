defprotocol CtfServer.CompletionMessage do
  @moduledoc """
  Optional message shown to a player when they capture a flag.

  Dispatched on the challenge struct (like `CtfServer.Challenge`), and given the
  team and the score just awarded so it can be tailored to the outcome — e.g.
  nudge a partial-credit finish that a better flag was missed, or congratulate a
  full solve. `challenge_live` appends the result to the capture flash.

  This is a separate protocol with `@fallback_to_any` rather than a function on
  `CtfServer.Challenge`: adding a function there would force all challenges to
  implement it (protocols have no per-function defaults). Here, a challenge that
  wants a message just implements this protocol; every other challenge falls back
  to the `Any` impl below, which returns `nil` (no extra message).
  """
  @fallback_to_any true

  @doc "Returns a short message to append to the capture flash, or `nil`."
  @spec message(t(), CtfServer.Accounts.Team.t(), non_neg_integer()) :: String.t() | nil
  def message(challenge, team, score)
end

defimpl CtfServer.CompletionMessage, for: Any do
  def message(_challenge, _team, _score), do: nil
end
