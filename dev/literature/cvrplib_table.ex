defmodule ExVrp.Literature.CvrplibTable do
  @moduledoc """
  The instance table on CVRPLib's instances page: per instance its upper bound (the
  best-known cost, in the source's own units) and whether that bound is a proven optimum.
  CVRPLib updates these bounds as new records come in, so the table is newer than the
  `.sol` files in its own archives.
  """

  @url "https://galgos.inf.puc-rio.br/cvrplib/en/instances"

  @row ~r{title="Instance File">\s*(?<name>\S+)\s*</a>.*?<span class="pe-none">\$(?<upper_bound>[^$]+)\$</span>.*?<span class="badge[^"]*">(?<optimal>yes|no)</span>}s

  @type bound :: %{upper_bound: float(), optimal: boolean()}

  @spec url() :: String.t()
  def url, do: @url

  @spec parse(String.t()) :: %{String.t() => bound()}
  def parse(html) do
    @row
    |> Regex.scan(html, capture: [:name, :upper_bound, :optimal])
    |> Map.new(fn [name, upper_bound, optimal] ->
      {name, %{upper_bound: parse_upper_bound(upper_bound), optimal: optimal == "yes"}}
    end)
  end

  defp parse_upper_bound(text) do
    {upper_bound, ""} = text |> String.replace("{,}", "") |> Float.parse()
    upper_bound
  end
end
