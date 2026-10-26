defmodule ExVrp.Literature.HtmlReport do
  @moduledoc """
  A literature run as one self-contained HTML page: the summary table, and per group the
  gap over the budget and each instance's gap against its size, with PyVRP's published
  gaps drawn as reference lines. Charts are inline SVG with a hover tooltip; colours
  follow the light and dark tokens at the top of the page.
  """

  alias ExVrp.Literature.Gap
  alias ExVrp.Literature.GroupSummary

  @width 340
  @height 190
  @margin %{left: 56, right: 12, top: 14, bottom: 28}

  @spec render([GroupSummary.t()], [map()]) :: String.t()
  def render(summaries, records) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>ExVrp Literature Benchmark</title>
    <style>#{styles()}</style>
    </head>
    <body>
    <main>
    <h1>ExVrp on literature benchmarks</h1>
    <p class="meta">#{escape(run_description(records))}</p>
    #{summary_table(summaries)}
    <div class="panels">#{Enum.map_join(summaries, "\n", &group_panel/1)}</div>
    </main>
    <div id="tip" role="tooltip"></div>
    <script>#{tooltip_script()}</script>
    </body>
    </html>
    """
  end

  defp run_description([]), do: "No results."

  defp run_description([first | _rest] = records) do
    "#{length(records)} solves · commit #{first["commit"]} · #{first["cpu"]} · " <>
      "PassMark #{first["passmark"] || "reference"} · budget scale #{first["budget_scale"]}"
  end

  defp summary_table(summaries) do
    rows =
      Enum.map_join(summaries, "\n", fn summary ->
        cells = [
          summary.group.id,
          summary.instances,
          summary.seeds,
          Gap.format(summary.mean_gap_to_bks),
          standard_error(summary.standard_error),
          published(summary, "0.13.0"),
          published(summary, "0.14.0"),
          Gap.format(summary.mean_gap_to_best_known),
          "#{summary.optimum_reached}/#{summary.proven_optimal}"
        ]

        "<tr>" <> Enum.map_join(cells, &"<td>#{escape(to_string(&1))}</td>") <> "</tr>"
      end)

    """
    <div class="table-scroll"><table>
    <thead><tr><th>Group</th><th>Instances</th><th>Seeds</th><th>Gap to BKS</th><th>± s.e.</th>
    <th>PyVRP 0.13.0</th><th>PyVRP 0.14.0</th><th>Gap to best known</th><th>Optima reached</th></tr></thead>
    <tbody>#{rows}</tbody>
    </table></div>
    """
  end

  defp standard_error(nil), do: "—"
  defp standard_error(value), do: Gap.format(value)

  defp published(%GroupSummary{group: %{pyvrp_published_gaps: nil}}, _version), do: "—"
  defp published(%GroupSummary{group: group}, version), do: "#{group.pyvrp_published_gaps[version]}%"

  defp group_panel(%GroupSummary{} = summary) do
    """
    <section class="panel">
    <h2>#{summary.group.id}</h2>
    <p class="meta">#{summary.instances} instances · mean gap #{Gap.format(summary.mean_gap_to_best_known)}</p>
    <h3>Mean gap over the budget</h3>
    #{budget_chart(summary.gap_over_budget)}
    <h3>Gap per instance by size</h3>
    #{instance_chart(summary)}
    </section>
    """
  end

  defp budget_chart(gap_over_budget) do
    points = for {fraction, gap} <- gap_over_budget, gap, do: {fraction, gap}
    y_scale = y_scale(Enum.map(points, &elem(&1, 1)))
    x_of = fn fraction -> @margin.left + fraction * (@width - @margin.left - @margin.right) end

    path = Enum.map_join(points, " ", fn {fraction, gap} -> "#{x_of.(fraction)},#{y_position(y_scale, gap)}" end)

    marks =
      Enum.map_join(points, "\n", fn {fraction, gap} ->
        dot(x_of.(fraction), y_position(y_scale, gap), "#{round(fraction * 100)}% of budget: #{Gap.format(gap)}")
      end)

    x_labels =
      Enum.map_join(points, "\n", fn {fraction, _gap} ->
        ~s(<text class="tick" x="#{x_of.(fraction)}" y="#{@height - 8}" text-anchor="#{tick_anchor(fraction)}">#{round(fraction * 100)}%</text>)
      end)

    svg(y_axis(y_scale) <> x_labels <> ~s(<polyline class="line" points="#{path}"/>) <> marks)
  end

  defp tick_anchor(1.0 = _whole_budget), do: "end"
  defp tick_anchor(_fraction), do: "middle"

  defp instance_chart(%GroupSummary{instance_gaps: instance_gaps, group: group}) do
    references = reference_lines(group.pyvrp_published_gaps)
    y_scale = y_scale(Enum.map(instance_gaps, & &1.gap) ++ Enum.map(references, &elem(&1, 1)))
    {smallest, largest} = instance_gaps |> Enum.map(& &1.num_clients) |> Enum.min_max(fn -> {0, 1} end)
    x_of = linear_x(smallest, largest)

    reference_marks =
      references
      |> Enum.zip([{@margin.left + 2, "start"}, {@width - @margin.right, "end"}])
      |> Enum.map_join("\n", fn {{label, gap}, {label_x, anchor}} ->
        y = y_position(y_scale, gap)

        ~s(<line class="reference" x1="#{@margin.left}" x2="#{@width - @margin.right}" y1="#{y}" y2="#{y}"/>) <>
          ~s(<text class="tick" x="#{label_x}" y="#{y - 4}" text-anchor="#{anchor}">#{label} #{Gap.format(gap)}</text>)
      end)

    marks =
      Enum.map_join(instance_gaps, "\n", fn %{name: name, num_clients: num_clients, gap: gap} ->
        dot(x_of.(num_clients), y_position(y_scale, gap), "#{name} (n=#{num_clients}): #{Gap.format(gap)}")
      end)

    x_labels =
      Enum.map_join(Enum.uniq([smallest, largest]), "\n", fn size ->
        ~s(<text class="tick" x="#{x_of.(size)}" y="#{@height - 8}" text-anchor="middle">n=#{size}</text>)
      end)

    svg(y_axis(y_scale) <> x_labels <> reference_marks <> marks)
  end

  defp reference_lines(nil), do: []

  defp reference_lines(published),
    do: published |> Enum.sort() |> Enum.map(fn {version, gap} -> {"PyVRP #{version}", gap / 100} end)

  defp linear_x(low, low), do: fn _size -> (@margin.left + @width - @margin.right) / 2 end

  defp linear_x(low, high) do
    span = @width - @margin.left - @margin.right - 16
    fn size -> @margin.left + 8 + (size - low) / (high - low) * span end
  end

  defp y_scale(gaps) do
    low = Enum.min([0.0 | gaps])
    %{low: low, high: max(Enum.max([0.0 | gaps]) * 1.15, low + 0.001)}
  end

  defp y_position(%{low: low, high: high}, gap) do
    Float.round(@margin.top + (high - gap) / (high - low) * (@height - @margin.top - @margin.bottom), 1)
  end

  defp y_axis(%{low: low, high: high} = y_scale) do
    Enum.map_join([low, (low + high) / 2, high], "\n", fn gap ->
      y = y_position(y_scale, gap)

      ~s(<line class="grid" x1="#{@margin.left}" x2="#{@width - @margin.right}" y1="#{y}" y2="#{y}"/>) <>
        ~s(<text class="tick" x="#{@margin.left - 6}" y="#{y + 4}" text-anchor="end">#{Gap.format(gap)}</text>)
    end)
  end

  defp dot(x, y, tip) do
    ~s(<g class="hit" data-tip="#{escape(tip)}"><circle class="target" cx="#{x}" cy="#{y}" r="10"/>) <>
      ~s(<circle class="dot" cx="#{x}" cy="#{y}" r="4"/></g>)
  end

  defp svg(content) do
    ~s(<svg viewBox="0 0 #{@width} #{@height}" role="img">#{content}</svg>)
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp styles do
    """
    :root { color-scheme: light; --surface: #fcfcfb; --page: #f9f9f7; --ink: #0b0b0b; --ink-2: #52514e;
      --muted: #898781; --grid: #e1e0d9; --border: rgba(11,11,11,0.10); --series-1: #2a78d6; }
    @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { color-scheme: dark; --surface: #1a1a19;
      --page: #0d0d0d; --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781; --grid: #2c2c2a;
      --border: rgba(255,255,255,0.10); --series-1: #3987e5; } }
    :root[data-theme="dark"] { color-scheme: dark; --surface: #1a1a19; --page: #0d0d0d; --ink: #ffffff;
      --ink-2: #c3c2b7; --muted: #898781; --grid: #2c2c2a; --border: rgba(255,255,255,0.10); --series-1: #3987e5; }
    body { margin: 0; background: var(--page); color: var(--ink); font: 14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
    main { max-width: 1120px; margin: 0 auto; padding: 24px 16px; }
    h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 16px; margin: 0; } h3 { font-size: 12px; color: var(--ink-2); margin: 12px 0 4px; font-weight: 600; }
    .meta { color: var(--ink-2); margin: 0 0 16px; }
    .table-scroll { overflow-x: auto; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; }
    table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
    th, td { padding: 6px 10px; text-align: right; border-bottom: 1px solid var(--grid); white-space: nowrap; }
    th:first-child, td:first-child { text-align: left; } th { color: var(--ink-2); font-weight: 600; }
    .panels { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 16px; margin-top: 24px; }
    .panel { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 14px; }
    svg { width: 100%; height: auto; display: block; }
    .grid { stroke: var(--grid); stroke-width: 1; } .tick { fill: var(--muted); font-size: 10px; font-variant-numeric: tabular-nums; }
    .line { fill: none; stroke: var(--series-1); stroke-width: 2; }
    .reference { stroke: var(--ink-2); stroke-width: 1; stroke-dasharray: 4 3; }
    .dot { fill: var(--series-1); stroke: var(--surface); stroke-width: 2; } .target { fill: transparent; }
    .hit:hover .dot { r: 5; }
    #tip { position: fixed; pointer-events: none; background: var(--surface); color: var(--ink); border: 1px solid var(--border);
      border-radius: 6px; padding: 4px 8px; font-size: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.15); display: none; }
    """
  end

  defp tooltip_script do
    """
    const tip = document.getElementById("tip");
    document.querySelectorAll("[data-tip]").forEach((mark) => {
      mark.addEventListener("mousemove", (event) => {
        tip.textContent = mark.dataset.tip;
        tip.style.display = "block";
        tip.style.left = Math.min(event.clientX + 12, window.innerWidth - tip.offsetWidth - 8) + "px";
        tip.style.top = (event.clientY + 12) + "px";
      });
      mark.addEventListener("mouseleave", () => { tip.style.display = "none"; });
    });
    """
  end
end
