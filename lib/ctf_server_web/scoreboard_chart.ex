defmodule CtfServerWeb.ScoreboardChart do
  @moduledoc """
  Builds the leaderboard's score-over-time Vega-Lite spec.

  The spec is built here and rendered in the browser by the `VegaChart` hook —
  Elixir never runs Vega, it only emits JSON.

  ## Why the chart looks the way it does

  * **Step line, not a smooth one.** Score is piecewise constant: it holds flat
    between captures and jumps when one lands. A smooth line would draw scores
    a team never had, and would imply a rate of scoring that isn't real.
  * **Palette is fixed and validated.** Eight categorical hues, assigned in a
    fixed order and never cycled, which is also why `Scoreboard` caps the chart
    at eight teams. Three of the eight sit below 3:1 contrast on a light
    surface, so the chart ships the required relief: end-of-line labels, plus
    the full standings table underneath it.
  * **Color follows the team, not the rank.** `Scoreboard.timeline/1` hands back
    team names in registration order, and the color scale's domain is pinned to
    that order. A lead change reorders the standings without repainting a
    single line.
  """

  alias VegaLite, as: Vl

  # Validated categorical palette (light surface): all checks pass, worst
  # adjacent CVD ΔE 9.1, worst adjacent normal-vision ΔE 19.6. Assign in this
  # order; never cycle for a ninth series.
  @palette ~w(#2a78d6 #eb6834 #1baf7a #eda100 #e87ba4 #008300 #4a3aa7 #e34948)
  @palette_size 8

  # Dash patterns as Vega stroke-dash arrays. Solid and dashed distinguish the
  # two passes through the palette; dotted is reserved for the viewer's own line.
  @solid [1, 0]
  @dashed [6, 3]
  @dotted [2, 2]

  # Direct-labelling more than four lines turns the right edge into a pile-up,
  # so past this the legend and the table carry identity.
  @direct_label_limit 4

  @surface "#ffffff"
  @ink_muted "#52514e"
  @grid "#e4e4e7"

  # Neutral ink for the viewer's own line when it isn't one of the leaders.
  @own_ink "#0b0b0b"

  @doc """
  The Vega-Lite spec as a plain map, ready to be JSON-encoded into the hook's
  data attribute.

  `points` and `team_names` come from `CtfServer.Scoreboard.timeline/1`.
  """
  def spec(points, series) do
    team_names = Enum.map(series, & &1.name)
    {colors, dashes} = encodings_for(series)

    # Right padding keeps the end markers (and their surface rings) off the plot
    # boundary — without it the rightmost dot is drawn half-clipped whenever
    # there are no direct labels reserving space out there.
    Vl.new(
      width: :container,
      height: 320,
      padding: [left: 4, top: 4, right: 18, bottom: 4],
      autosize: [type: "fit-x", contains: "padding"]
    )
    |> Vl.data_from_values(points)
    |> Vl.config(
      view: [stroke: nil],
      background: @surface,
      axis: [
        label_color: @ink_muted,
        title_color: @ink_muted,
        domain_color: @grid,
        tick_color: @grid,
        grid_color: @grid,
        label_font_size: 11,
        title_font_size: 11
      ],
      legend: [
        label_color: @ink_muted,
        title_color: @ink_muted,
        symbol_type: "stroke",
        symbol_stroke_width: 2
      ],
      # The score axis config lives here rather than on the line layer's
      # encoding: layers share one merged y axis, and a layer that mentions y
      # without an axis block wins the merge — which is how this silently ended
      # up labelling scores in scientific notation ("2e+3") instead of "2,000".
      axis_y: [format: ",d", tick_count: 5]
    )
    |> Vl.layers(layers(series, team_names, colors, dashes))
    |> Vl.to_spec()
  end

  # Hue and dash together identify a series.
  #
  # There are eight hues and up to sixteen leaders, so slots are reused — but a
  # reused hue is never ambiguous, because the second pass through the palette
  # is dashed. That is composite encoding (two channels carrying one identity),
  # not a cycled palette: nothing on screen shares both a hue and a dash.
  #
  # The viewer's own team is outside the scheme entirely — neutral ink, dotted,
  # and always directly labelled.
  defp encodings_for(series) do
    {leaders, own} = Enum.split_with(series, &(not &1.own?))

    leader_styles =
      leaders
      |> Enum.with_index()
      |> Enum.map(fn {_series, index} ->
        {Enum.at(@palette, rem(index, @palette_size)),
         if(index < @palette_size, do: @solid, else: @dashed)}
      end)

    own_styles = Enum.map(own, fn _ -> {@own_ink, @dotted} end)

    # Rebuilt in the caller's original order, since the color and dash scale
    # domains are the series names in that order.
    styles = restore_order(series, leader_styles, own_styles)

    {Enum.map(styles, &elem(&1, 0)), Enum.map(styles, &elem(&1, 1))}
  end

  defp restore_order(series, leader_styles, own_styles) do
    {styles, _, _} =
      Enum.reduce(series, {[], leader_styles, own_styles}, fn
        %{own?: false}, {acc, [style | leaders], own} -> {[style | acc], leaders, own}
        %{own?: true}, {acc, leaders, [style | own]} -> {[style | acc], leaders, own}
      end)

    Enum.reverse(styles)
  end

  defp layers(series, team_names, colors, dashes) do
    [line_layer(team_names, colors, dashes), edge_layer(team_names, colors)] ++
      label_layer(series, team_names, colors) ++ [crosshair_layer(team_names)]
  end

  # The lines themselves: 2px, round joins, stepped after each capture. The
  # viewer's own line is dashed so it reads as "yours" rather than as a ninth
  # competitor, and stays distinguishable from the neutral crosshair.
  defp line_layer(team_names, colors, dashes) do
    # `columns` wraps the legend into rows instead of letting a single line of
    # up to seventeen entries run off the right edge, and `label_limit`
    # ellipsizes a long team name rather than pushing its neighbours out.
    legend = [
      title: nil,
      orient: "top",
      direction: "horizontal",
      columns: 6,
      label_limit: 120
    ]

    Vl.new()
    |> Vl.mark(:line,
      interpolate: "step-after",
      stroke_width: 2,
      stroke_join: "round",
      stroke_cap: "round"
    )
    # Dash keys off the team, exactly like color does, so Vega-Lite merges the
    # two into a single legend whose swatches carry hue *and* dash together —
    # the pair is what identifies a series once the palette is reused.
    |> Vl.encode_field(:stroke_dash, "team",
      type: :nominal,
      scale: [domain: team_names, range: dashes],
      legend: legend
    )
    |> Vl.encode_field(:x, "at",
      type: :temporal,
      title: nil,
      axis: [grid: false, format: "%H:%M"]
    )
    |> Vl.encode_field(:y, "score", type: :quantitative, title: "Score", axis: [grid: true])
    |> color(team_names, colors, legend: legend)
  end

  # End-of-line marker: ≥8px, filled with the series color, ringed in the
  # surface color so it stays legible where lines cross.
  defp edge_layer(team_names, colors) do
    Vl.new()
    |> Vl.transform(filter: "datum.edge")
    |> Vl.mark(:point, filled: true, size: 80, stroke: @surface, stroke_width: 2, opacity: 1)
    |> Vl.encode_field(:x, "at", type: :temporal)
    |> Vl.encode_field(:y, "score", type: :quantitative)
    |> color(team_names, colors, [])
  end

  # Direct labels ride the end of each line — but only while there are few
  # enough that they don't collide. The viewer's own line is the exception: it
  # is always labelled, however crowded the right edge, because it is the one
  # line that reader came to find.
  defp label_layer(series, team_names, colors) do
    crowded? = length(team_names) > @direct_label_limit
    own? = Enum.any?(series, & &1.own?)

    cond do
      not crowded? -> [label_mark("datum.edge", team_names, colors)]
      own? -> [label_mark("datum.edge && datum.own", team_names, colors)]
      true -> []
    end
  end

  defp label_mark(filter, team_names, colors) do
    Vl.new()
    |> Vl.transform(filter: filter)
    # `limit` ellipsizes rather than letting a long name run off the plot —
    # team names are player-chosen, so they can be any length.
    |> Vl.mark(:text, align: "left", dx: 10, dy: 0, font_size: 11, font_weight: 600, limit: 110)
    |> Vl.encode_field(:x, "at", type: :temporal)
    |> Vl.encode_field(:y, "score", type: :quantitative)
    |> Vl.encode_field(:text, "team", type: :nominal)
    |> color(team_names, colors, [])
  end

  # Crosshair: a hairline that snaps to the nearest time and reports *every*
  # team's score there, so the reader aims at a moment rather than at a 2px
  # line. The pivot is what makes one tooltip carry all the series; it works
  # because the timeline is densified onto a shared time axis.
  defp crosshair_layer(team_names) do
    tooltip =
      [[field: "at", type: :temporal, title: "At", format: "%H:%M:%S"]] ++
        Enum.map(team_names, &[field: &1, type: :quantitative])

    Vl.new()
    |> Vl.transform(pivot: "team", value: "score", groupby: ["at"])
    |> Vl.mark(:rule, stroke: @ink_muted, stroke_width: 1)
    |> Vl.encode_field(:x, "at", type: :temporal)
    |> Vl.encode(:opacity,
      condition: [param: "crosshair", value: 0.35, empty: false],
      value: 0
    )
    |> Vl.encode(:tooltip, tooltip)
    |> Vl.param("crosshair",
      select: [
        type: :point,
        fields: ["at"],
        nearest: true,
        on: "pointerover",
        clear: "pointerout"
      ]
    )
  end

  # Every layer shares one color encoding so they share one merged legend. Only
  # the line layer states legend options; the others inherit rather than passing
  # `legend: nil`, which would ask Vega-Lite to both draw and suppress the same
  # legend and make it warn about the conflict.
  defp color(vl, team_names, colors, opts) do
    scale = [domain: team_names, range: colors]

    case Keyword.fetch(opts, :legend) do
      {:ok, legend} ->
        Vl.encode_field(vl, :color, "team", type: :nominal, scale: scale, legend: legend)

      :error ->
        Vl.encode_field(vl, :color, "team", type: :nominal, scale: scale)
    end
  end
end
