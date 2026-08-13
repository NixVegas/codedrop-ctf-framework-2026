defmodule CtfServerWeb.ScoreboardChartTest do
  use ExUnit.Case, async: true

  alias CtfServerWeb.ScoreboardChart

  defp series(names, own \\ []) do
    Enum.map(names, &%{name: &1, own?: &1 in own})
  end

  defp points(names) do
    for name <- names, i <- 0..2 do
      %{
        team: name,
        at: DateTime.add(~U[2026-08-06 11:00:00.000000Z], i * 600, :second),
        score: i * 100,
        edge: i == 2,
        own: false
      }
    end
  end

  defp layer_with_mark(spec, type) do
    Enum.find(spec["layer"], fn layer ->
      mark = layer["mark"]
      is_map(mark) and mark["type"] == type
    end)
  end

  defp color_scale(spec) do
    spec["layer"] |> hd() |> get_in(["encoding", "color", "scale"])
  end

  test "encodes as JSON, since it is handed to the browser in an attribute" do
    spec = ScoreboardChart.spec(points(["A"]), series(["A"]))

    assert is_binary(Jason.encode!(spec))
  end

  test "pins the color domain to the given series order" do
    names = ["Charlie", "Alpha", "Bravo"]
    spec = ScoreboardChart.spec(points(names), series(names))

    assert color_scale(spec)["domain"] == names,
           "the domain follows the caller's stable order, not an alphabetical or rank one"
  end

  test "assigns one palette hue per series without cycling" do
    names = Enum.map(1..8, &"Team #{&1}")
    spec = ScoreboardChart.spec(points(names), series(names))

    colors = color_scale(spec)["range"]

    assert length(colors) == 8
    assert length(Enum.uniq(colors)) == 8, "no hue is reused for a second series"
  end

  test "draws the score as a step line, never interpolated between captures" do
    spec = ScoreboardChart.spec(points(["A"]), series(["A"]))

    assert layer_with_mark(spec, "line")["mark"]["interpolate"] == "step-after"
  end

  test "direct-labels every line while there are few enough to fit" do
    names = ["A", "B", "C"]
    spec = ScoreboardChart.spec(points(names), series(names))

    text = layer_with_mark(spec, "text")
    assert text["transform"] == [%{"filter" => "datum.edge"}]
  end

  test "drops direct labels once the right edge would be crowded" do
    names = Enum.map(1..8, &"Team #{&1}")
    spec = ScoreboardChart.spec(points(names), series(names))

    refute layer_with_mark(spec, "text"), "the legend and table carry identity instead"
  end

  describe "the viewer's own team" do
    test "is labelled even when the chart is otherwise too crowded to label" do
      names = Enum.map(1..8, &"Team #{&1}") ++ ["Mine"]
      spec = ScoreboardChart.spec(points(names), series(names, ["Mine"]))

      text = layer_with_mark(spec, "text")

      assert text, "the viewer's line is always labelled"
      assert text["transform"] == [%{"filter" => "datum.edge && datum.own"}]
    end

    test "takes neutral ink rather than a ninth categorical hue" do
      names = Enum.map(1..8, &"Team #{&1}") ++ ["Mine"]
      spec = ScoreboardChart.spec(points(names), series(names, ["Mine"]))

      colors = color_scale(spec)["range"]

      assert length(colors) == 9
      assert List.last(colors) == "#0b0b0b"
      assert length(Enum.uniq(Enum.take(colors, 8))) == 8, "the eight hues are untouched"
    end

    test "is dotted, so identity does not rest on color alone" do
      spec = ScoreboardChart.spec(points(["A", "Mine"]), series(["A", "Mine"], ["Mine"]))

      dash = layer_with_mark(spec, "line")["encoding"]["strokeDash"]

      assert dash["field"] == "team", "dash keys off the team so it merges with the color legend"
      assert dash["scale"]["domain"] == ["A", "Mine"]

      assert dash["scale"]["range"] == [[1, 0], [2, 2]],
             "the own line is dotted, the leader solid"
    end
  end

  describe "beyond eight series" do
    test "reuses the eight hues but never a hue-and-dash pair" do
      names = Enum.map(1..16, &"Team #{&1}")
      spec = ScoreboardChart.spec(points(names), series(names))

      line = layer_with_mark(spec, "line")["encoding"]
      colors = line["color"]["scale"]["range"]
      dashes = line["strokeDash"]["scale"]["range"]

      assert length(colors) == 16
      assert length(Enum.uniq(colors)) == 8, "the palette is reused, exactly twice"

      pairs = Enum.zip(colors, dashes)
      assert length(Enum.uniq(pairs)) == 16, "no two series share both a hue and a dash"
    end

    test "draws the first pass solid and the second dashed" do
      names = Enum.map(1..16, &"Team #{&1}")
      spec = ScoreboardChart.spec(points(names), series(names))

      dashes = layer_with_mark(spec, "line")["encoding"]["strokeDash"]["scale"]["range"]

      assert Enum.take(dashes, 8) == List.duplicate([1, 0], 8)
      assert Enum.drop(dashes, 8) == List.duplicate([6, 3], 8)
    end

    test "wraps the legend instead of letting seventeen entries run off the edge" do
      names = Enum.map(1..16, &"Team #{&1}") ++ ["Mine"]
      spec = ScoreboardChart.spec(points(names), series(names, ["Mine"]))

      legend = layer_with_mark(spec, "line")["encoding"]["color"]["legend"]

      assert legend["columns"] == 6
    end
  end

  test "reports every series in one tooltip at the hovered time" do
    names = ["A", "B"]
    spec = ScoreboardChart.spec(points(names), series(names))

    rule = layer_with_mark(spec, "rule")
    tooltip_fields = Enum.map(rule["encoding"]["tooltip"], & &1["field"])

    assert "A" in tooltip_fields
    assert "B" in tooltip_fields
  end

  test "labels the score axis in plain thousands rather than scientific notation" do
    spec = ScoreboardChart.spec(points(["A"]), series(["A"]))

    assert spec["config"]["axisY"]["format"] == ",d"
  end
end
