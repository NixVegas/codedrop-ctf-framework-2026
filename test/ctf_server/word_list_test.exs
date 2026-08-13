defmodule CtfServer.WordListTest do
  use ExUnit.Case, async: true
  alias CtfServer.WordList

  test "pool is non-trivial and deduped" do
    words = WordList.words()
    assert length(words) > 5000
    assert length(words) == length(Enum.uniq(words))
  end

  test "code/1 makes the requested number of words from the pool" do
    pool = MapSet.new(WordList.words())
    parts = WordList.code(3) |> String.split("-")
    assert length(parts) == 3
    assert Enum.all?(parts, &MapSet.member?(pool, &1))
  end
end
