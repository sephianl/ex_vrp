defmodule ExVrp.Literature.Fetch do
  @moduledoc """
  Downloads the literature instances and builds the manifest: `PyVRP/Instances` at a pinned
  commit, and CVRPLib's DIMACS, Solomon and Homberger–Gehring archives plus its table of
  current upper bounds. Archives already on disk are not downloaded again; the bounds are
  refreshed on every fetch.

  Every best-known solution is evaluated on our model, and the fetch reports a problem when
  one is infeasible there or its cost disagrees with what its source states: either means
  we read the instance differently from the source, and its gaps would be meaningless.
  """

  alias ExVrp.Literature.BenchmarkGroup
  alias ExVrp.Literature.BenchmarkInstance
  alias ExVrp.Literature.BestKnownSolution
  alias ExVrp.Literature.CvrplibTable
  alias ExVrp.Literature.Download
  alias ExVrp.Literature.Manifest
  alias ExVrp.Literature.SolomonFormat
  alias ExVrp.Read

  @pyvrp_instances_commit "7474b068a8effa7f39448b241314b615c9271525"
  @cvrplib_set_ids %{"DIMACS" => 19, "Solomon" => 22, "Holmberger" => 23}
  @cvrplib_download "https://galgos.inf.puc-rio.br/cvrplib/en/download/instance-set/"
  @round_func_scale %{round: 1, dimacs: 10, exact: 1000}

  @spec run() :: {:ok, [BenchmarkInstance.t()], [String.t()]} | {:error, String.t()}
  def run do
    File.mkdir_p!(Manifest.data_dir())

    with :ok <- fetch_pyvrp_instances(),
         :ok <- fetch_cvrplib_sets(),
         {:ok, html} <- Download.get(CvrplibTable.url()) do
      {instances, problems} = build_instances(CvrplibTable.parse(html))
      Manifest.write(instances, provenance())
      {:ok, instances, problems}
    end
  end

  defp fetch_pyvrp_instances do
    pyvrp_instances_root()
    |> File.dir?()
    |> download_pyvrp_instances()
  end

  defp download_pyvrp_instances(true = _present), do: :ok

  defp download_pyvrp_instances(false = _present) do
    with {:ok, tarball} <- Download.get("https://codeload.github.com/PyVRP/Instances/tar.gz/#{@pyvrp_instances_commit}") do
      :erl_tar.extract({:binary, tarball}, [:compressed, cwd: String.to_charlist(Manifest.data_dir())])
    end
  end

  defp fetch_cvrplib_sets do
    Enum.reduce_while(@cvrplib_set_ids, :ok, fn {set_dir, set_id}, :ok ->
      case fetch_cvrplib_set(set_dir, set_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp fetch_cvrplib_set(set_dir, set_id) do
    cvrplib_root()
    |> Path.join(set_dir)
    |> File.dir?()
    |> download_cvrplib_set(set_id)
  end

  defp download_cvrplib_set(true = _present, _set_id), do: :ok

  defp download_cvrplib_set(false = _present, set_id) do
    archive = Path.join(Manifest.data_dir(), "cvrplib-set-#{set_id}.7z")

    with {:ok, body} <- Download.get(@cvrplib_download <> Integer.to_string(set_id)),
         :ok <- File.write(archive, body) do
      extract_7z(archive, System.find_executable("7z"))
    end
  end

  defp extract_7z(_archive, nil), do: {:error, "7z is not on the PATH; it ships with p7zip (devenv.nix)"}

  defp extract_7z(archive, seven_zip) do
    case System.cmd(seven_zip, ["x", "-y", "-o" <> cvrplib_root(), archive], stderr_to_stdout: true, env: %{}) do
      {_output, 0} -> File.rm(archive)
      {output, status} -> {:error, "7z exited #{status} on #{archive}: #{output}"}
    end
  end

  defp build_instances(cvrplib_bounds) do
    BenchmarkGroup.all()
    |> Enum.flat_map(fn group -> Enum.map(source_files(group), &{group, &1}) end)
    |> Task.async_stream(fn {group, file} -> build_instance(group, file, cvrplib_bounds) end,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.reduce({[], []}, &collect_instance/2)
    |> then(fn {instances, problems} -> {Enum.reverse(instances), Enum.reverse(problems)} end)
  end

  defp collect_instance({:ok, {:ok, instance, problems}}, {instances, all_problems}),
    do: {[instance | instances], Enum.reverse(problems, all_problems)}

  defp collect_instance({:ok, {:error, problem}}, {instances, problems}), do: {instances, [problem | problems]}

  defp source_files(%BenchmarkGroup{source: {archive, dir, glob}}) do
    archive
    |> source_root()
    |> Path.join(dir)
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp source_root(:pyvrp_instances), do: pyvrp_instances_root()
  defp source_root(:cvrplib), do: cvrplib_root()

  defp pyvrp_instances_root, do: Path.join(Manifest.data_dir(), "Instances-#{@pyvrp_instances_commit}")
  defp cvrplib_root, do: Path.join(Manifest.data_dir(), "cvrplib")

  defp build_instance(group, source_file, cvrplib_bounds) do
    vrp_path = vrplib_file(source_file, Path.extname(source_file))
    name = Path.basename(vrp_path, ".vrp")
    model = Read.read(vrp_path, round_func: group.round_func)
    best_known_solution = vrp_path |> Path.rootname() |> Kernel.<>(".sol") |> File.read!() |> BestKnownSolution.parse()

    case BestKnownSolution.evaluate(best_known_solution, model) do
      {:ok, bks} ->
        instance = %BenchmarkInstance{
          name: name,
          group: group.id,
          num_clients: length(model.clients),
          path: Path.relative_to(vrp_path, Manifest.data_dir()),
          bks: bks
        }

        {:ok, with_cvrplib_bound(instance, cvrplib_bounds[name], best_known_solution, group.round_func),
         bks_problems(name, bks, best_known_solution, cvrplib_bounds[name], group.round_func)}

      {:error, reason} ->
        {:error, "#{group.id}/#{name}: #{reason}"}
    end
  end

  defp vrplib_file(txt_file, ".txt") do
    vrp_path = Path.rootname(txt_file) <> ".vrp"
    File.write!(vrp_path, txt_file |> File.read!() |> SolomonFormat.to_vrplib())
    vrp_path
  end

  defp vrplib_file(vrp_file, ".vrp"), do: vrp_file

  defp with_cvrplib_bound(instance, nil = _bound, %BestKnownSolution{optimal: optimal}, _round_func),
    do: %{instance | optimal: optimal == true}

  defp with_cvrplib_bound(instance, %{upper_bound: upper_bound, optimal: optimal}, _solution, round_func) do
    cvrplib_bound = in_solver_units(upper_bound, round_func)
    %{instance | cvrplib_bound: cvrplib_bound, optimal: optimal and cvrplib_bound <= instance.bks}
  end

  defp in_solver_units(cost, round_func), do: round(cost * Map.fetch!(@round_func_scale, round_func))

  defp bks_problems(name, bks, %BestKnownSolution{stated_cost: stated_cost}, cvrplib_bound, round_func) do
    Enum.reject(
      [stated_cost_problem(name, bks, stated_cost), cvrplib_bound_problem(name, bks, cvrplib_bound, round_func)],
      &is_nil/1
    )
  end

  defp stated_cost_problem(_name, _bks, nil = _stated_cost), do: nil

  defp stated_cost_problem(name, bks, stated_cost) do
    0..5
    |> Enum.any?(&(abs(stated_cost * 10 ** &1 - bks) <= max(1, bks * 1.0e-6)))
    |> stated_cost_mismatch(name, bks, stated_cost)
  end

  defp stated_cost_mismatch(true = _matches_a_power_of_ten, _name, _bks, _stated_cost), do: nil

  defp stated_cost_mismatch(false, name, bks, stated_cost),
    do: "#{name}: best-known solution costs #{bks} on our model, but its file states #{stated_cost}"

  defp cvrplib_bound_problem(_name, _bks, nil = _bound, _round_func), do: nil

  defp cvrplib_bound_problem(name, bks, %{upper_bound: upper_bound}, round_func) do
    below_cvrplib_bound(bks < in_solver_units(upper_bound, round_func), name, bks, upper_bound)
  end

  defp below_cvrplib_bound(false, _name, _bks, _upper_bound), do: nil

  defp below_cvrplib_bound(true, name, bks, upper_bound),
    do: "#{name}: best-known solution costs #{bks} on our model, below CVRPLib's upper bound #{upper_bound}"

  defp provenance do
    %{
      "pyvrp_instances_commit" => @pyvrp_instances_commit,
      "cvrplib_bounds_fetched_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end
end
