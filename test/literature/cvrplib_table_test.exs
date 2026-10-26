defmodule ExVrp.Literature.CvrplibTableTest do
  use ExUnit.Case, async: true

  alias ExVrp.Literature.CvrplibTable

  defp row(name, upper_bound, optimal) do
    """
    <tr class="collapse border-bottom" id="set-17">
      <td class="text-center font-monospace text-nowrap">
        <a href="/cvrplib/en/download/instance/1" title="Instance File"> #{name} </a>
      </td>
      <td class="text-end">$100$</td>
      <td class="text-end">
        <a href="/cvrplib/en/download/bks/1" title="Solution File">
          <span class="pe-none">$#{upper_bound}$</span>
        </a>
      </td>
      <td class="text-center"><span class="badge rounded-pill bg-success-subtle">#{optimal}</span></td>
    </tr>
    """
  end

  test "reads each instance's upper bound and whether it is proven optimal" do
    html = row("XL-n10001-k1570", "2{,}329{,}810.00", "no") <> row("C101", "827.30", "yes")

    assert CvrplibTable.parse(html) == %{
             "XL-n10001-k1570" => %{upper_bound: 2_329_810.0, optimal: false},
             "C101" => %{upper_bound: 827.3, optimal: true}
           }
  end
end
