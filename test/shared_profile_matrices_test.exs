defmodule ExVrp.SharedProfileMatricesTest do
  @moduledoc """
  Profiles that share a matrix and replace one row of it, and matrices given as binaries, must
  solve exactly as the same profiles do with every matrix written out in full as nested lists.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Matrix
  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  @num_clients 24

  defp coordinates do
    [{0, 0} | for(i <- 1..@num_clients, do: {rem(i * 37, 101) * 10, rem(i * 59, 97) * 10})]
  end

  defp scaled_matrix(factor) do
    points = coordinates()

    for from <- points do
      for to <- points, do: round(factor * euclidean(from, to))
    end
  end

  defp euclidean({x1, y1}, {x2, y2}), do: :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)

  defp depot_row(matrix, factor), do: matrix |> hd() |> Enum.map(&round(&1 * factor))

  defp base_model(vehicle_opts) do
    model = Model.add_depot(Model.new(), tw_late: 20_000)

    model =
      Enum.reduce(1..@num_clients, model, fn i, model ->
        Model.add_client(model,
          delivery: [rem(i, 4) + 1],
          service_duration: 60,
          tw_early: rem(i * 311, 4_000),
          tw_late: rem(i * 311, 4_000) + 6_000,
          required: false,
          prize: 5_000
        )
      end)

    Enum.reduce(0..2, model, fn profile, model ->
      Model.add_vehicle_type(
        model,
        Keyword.merge(
          [num_available: 2, capacity: [20], time_windows: [{0, 20_000}], profile: profile, unit_duration_cost: 1],
          vehicle_opts
        )
      )
    end)
  end

  defp matrices do
    car = scaled_matrix(1.0)
    van = scaled_matrix(1.4)
    %{car: car, van: van, car_rush: depot_row(car, 1.3), van_rush: depot_row(van, 1.2)}
  end

  defp materialised(model) do
    %{car: car, van: van, car_rush: car_rush, van_rush: van_rush} = matrices()
    all = [car, List.replace_at(car, 0, car_rush), List.replace_at(van, 0, van_rush)]

    model
    |> Model.set_distance_matrices(all)
    |> Model.set_duration_matrices(all)
  end

  defp shared(model) do
    %{car: car, van: van, car_rush: car_rush, van_rush: van_rush} = matrices()
    bases = [Matrix.from_lists(car), Matrix.from_lists(van)]

    model
    |> Model.set_distance_matrices(bases)
    |> Model.set_duration_matrices(bases)
    |> Model.set_profiles([
      %{matrix: 0, override_row: nil},
      %{matrix: 0, override_row: {0, Matrix.row_from_list(car_rush), car_rush}},
      %{matrix: 1, override_row: {0, van_rush, Matrix.row_from_list(van_rush)}}
    ])
  end

  defp solved(model) do
    {:ok, result} =
      Solver.solve(model, stop: StoppingCriteria.max_iterations(400), seed: 42, num_starts: 1)

    best = result.best

    %{
      routes: Enum.map(Solution.routes(best), &{Route.vehicle_type(&1), Route.visits(&1)}),
      distance: Solution.distance(best),
      duration: Solution.duration(best),
      feasible: Solution.feasible?(best)
    }
  end

  defp problem_data(model) do
    {:ok, problem_data} = Model.to_problem_data(model)
    problem_data
  end

  describe "a profile replacing a row of a shared matrix" do
    test "solves exactly as its matrix written out in full" do
      model = base_model([])
      expected = solved(materialised(model))

      assert solved(shared(model)) == expected
      assert expected.routes != []
    end

    test "solves exactly as its matrix written out in full with a break pool appended" do
      model = base_model(max_drive_between_breaks: 3_000, break_duration: 300)

      assert solved(shared(model)) == solved(materialised(model))
    end

    test "gives the solver the same matrices, edge means and neighbours" do
      model = base_model([])
      full = problem_data(materialised(model))
      lean = problem_data(shared(model))

      for profile <- 0..2 do
        assert Native.problem_data_distance_matrix_nif(lean, profile) ==
                 Native.problem_data_distance_matrix_nif(full, profile)

        assert Native.problem_data_duration_matrix_nif(lean, profile) ==
                 Native.problem_data_duration_matrix_nif(full, profile)
      end

      assert Native.problem_data_mean_edge_measures(lean) == Native.problem_data_mean_edge_measures(full)
      assert Native.build_neighbours_nif(lean) == Native.build_neighbours_nif(full)
    end

    test "reads back as its matrix written out in full" do
      model = base_model([])
      full = materialised(model)
      lean = shared(model)

      for profile <- 0..2 do
        assert Model.distance_matrix(lean, profile) == Model.distance_matrix(full, profile)
        assert Model.duration_matrix(lean, profile) == Model.duration_matrix(full, profile)
      end
    end
  end

  describe "a matrix given as a binary" do
    test "decodes to the same matrix as its nested lists" do
      model = base_model([])
      %{car: car, van: van} = matrices()

      as_lists = model |> Model.set_distance_matrices([car, van, car]) |> Model.set_duration_matrices([van, car, van])

      as_binaries =
        model
        |> Model.set_distance_matrices(Enum.map([car, van, car], &Matrix.from_lists/1))
        |> Model.set_duration_matrices(Enum.map([van, car, van], &Matrix.from_lists/1))

      from_lists = problem_data(as_lists)
      from_binaries = problem_data(as_binaries)

      for profile <- 0..2 do
        assert Native.problem_data_distance_matrix_nif(from_binaries, profile) ==
                 Native.problem_data_distance_matrix_nif(from_lists, profile)

        assert Native.problem_data_duration_matrix_nif(from_binaries, profile) ==
                 Native.problem_data_duration_matrix_nif(from_lists, profile)
      end

      assert solved(as_binaries) == solved(as_lists)
    end

    test "round-trips through ExVrp.Matrix, negative cells included" do
      rows = [[0, -1, 2], [3, 0, -9_007_199_254_740_993], [7, 8, 0]]

      assert rows |> Matrix.from_lists() |> Matrix.to_lists() == rows
      assert rows |> Matrix.from_lists() |> Matrix.pad(2) |> Matrix.to_lists() == Matrix.pad(rows, 2)
    end
  end

  describe "validate/1" do
    setup do
      model = base_model([])
      %{car: car} = matrices()
      %{model: model, car: car, size: @num_clients + 1}
    end

    test "rejects a binary matrix of the wrong size", %{model: model, car: car} do
      short = binary_part(Matrix.from_lists(car), 0, 8 * 10)
      model = model |> Model.set_distance_matrices([short]) |> Model.set_duration_matrices([car])

      assert {:error, errors} = Model.validate(model)
      assert "Distance matrix dimensions don't match number of locations" in errors
    end

    test "rejects a binary matrix with a nonzero diagonal", %{model: model, car: car} do
      model =
        model
        |> Model.set_distance_matrices([car])
        |> Model.set_duration_matrices([
          car |> List.replace_at(3, car |> Enum.at(3) |> List.replace_at(3, 1)) |> Matrix.from_lists()
        ])

      assert {:error, errors} = Model.validate(model)
      assert "Duration matrix diagonal must be zero" in errors
    end

    test "rejects profiles that name a missing matrix, a missing row or a short row",
         %{model: model, car: car, size: size} do
      row = hd(car)

      model =
        model
        |> Model.set_distance_matrices([car])
        |> Model.set_duration_matrices([car])
        |> Model.set_profiles([
          %{matrix: 1, override_row: nil},
          %{matrix: 0, override_row: {size, row, row}},
          %{matrix: 0, override_row: {0, Enum.drop(row, 1), Matrix.row_from_list(row)}},
          %{matrix: 0, override_row: {0, row, Matrix.row_from_list([5 | tl(row)])}},
          %{matrix: 0}
        ])

      assert {:error, errors} = Model.validate(model)

      assert "Profile 0 names matrix 1, but there are 1" in errors

      assert Enum.any?(
               errors,
               &String.starts_with?(&1, "Profile 1 override_row must be nil or {row, distances, durations}")
             )

      assert "Profile 2 override distance row must hold one cell per location" in errors
      assert "Profile 3 override duration row must be zero on the diagonal" in errors
      assert Enum.any?(errors, &String.starts_with?(&1, "Profile 4 is not a %{matrix:, override_row:} map"))
    end

    test "counts penalty lists against the profiles, not the matrices", %{model: model, car: car, size: size} do
      model =
        model
        |> Model.set_distance_matrices([car])
        |> Model.set_duration_matrices([car])
        |> Model.set_profiles(List.duplicate(%{matrix: 0, override_row: nil}, 3))
        |> Model.set_penalties(List.duplicate(List.duplicate(0, size), 3))

      assert Model.validate(model) == :ok
    end
  end

  describe "the solver" do
    test "rejects a binary matrix of the wrong size that skipped validation" do
      model = base_model([])
      %{car: car} = matrices()
      short = binary_part(Matrix.from_lists(car), 0, 8 * 10)
      model = model |> Model.set_distance_matrices([short]) |> Model.set_duration_matrices([car])

      assert_raise ArgumentError, ~r/Matrix binary holds 10 values, expected 625/, fn ->
        Native.create_problem_data(model)
      end
    end

    test "rejects an override row naming a missing location that skipped validation" do
      model = base_model([])
      %{car: car} = matrices()

      model =
        model
        |> Model.set_distance_matrices([car])
        |> Model.set_duration_matrices([car])
        |> Model.set_profiles(List.duplicate(%{matrix: 0, override_row: {99, hd(car), hd(car)}}, 3))

      assert_raise RuntimeError, fn ->
        Native.create_problem_data(model)
      end
    end
  end
end
