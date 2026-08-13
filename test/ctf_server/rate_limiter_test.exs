defmodule CtfServer.RateLimiterTest do
  # Exercises the ETS fixed-window limiter that guards the auth endpoints
  # against brute-force and Argon2 CPU-exhaustion (CWE-307). Each test uses a
  # unique bucket/id so the shared table never cross-contaminates.
  use ExUnit.Case, async: true

  alias CtfServer.RateLimiter

  test "allows requests up to the limit, then denies" do
    id = "id-#{System.unique_integer([:positive])}"

    assert {:allow, 1} = RateLimiter.hit(:test, id, 3, 60_000)
    assert {:allow, 2} = RateLimiter.hit(:test, id, 3, 60_000)
    assert {:allow, 3} = RateLimiter.hit(:test, id, 3, 60_000)
    assert {:deny, retry_after} = RateLimiter.hit(:test, id, 3, 60_000)
    assert retry_after > 0
    assert retry_after <= 60_000
  end

  test "counts each id independently" do
    a = "a-#{System.unique_integer([:positive])}"
    b = "b-#{System.unique_integer([:positive])}"

    assert {:allow, 1} = RateLimiter.hit(:test, a, 1, 60_000)
    assert {:deny, _} = RateLimiter.hit(:test, a, 1, 60_000)
    # A different id is untouched by a's exhausted bucket.
    assert {:allow, 1} = RateLimiter.hit(:test, b, 1, 60_000)
  end

  test "a fresh window resets the count" do
    id = "id-#{System.unique_integer([:positive])}"
    # Pin `now` so the window boundary is deterministic (no sleeping).
    base = 1_000_000

    assert {:allow, 1} = RateLimiter.hit(:test, id, 1, 1_000, base)
    assert {:deny, _} = RateLimiter.hit(:test, id, 1, 1_000, base + 500)
    # One second later we are in the next window; the count starts over.
    assert {:allow, 1} = RateLimiter.hit(:test, id, 1, 1_000, base + 1_000)
  end

  test "check/2 reads the limit and window from config" do
    id = "id-#{System.unique_integer([:positive])}"
    # Merge in a unique bucket rather than replacing the map, so concurrent
    # async tests keep seeing the real login/register/password_reset limits.
    original = Application.get_env(:ctf_server, :rate_limits, [])

    Application.put_env(
      :ctf_server,
      :rate_limits,
      Keyword.put(original, :test_bucket, {2, 60_000})
    )

    on_exit(fn -> Application.put_env(:ctf_server, :rate_limits, original) end)

    assert {:allow, 1} = RateLimiter.check(:test_bucket, id)
    assert {:allow, 2} = RateLimiter.check(:test_bucket, id)
    assert {:deny, _} = RateLimiter.check(:test_bucket, id)
  end
end
