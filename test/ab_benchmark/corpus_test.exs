defmodule ExVrp.ABBenchmark.CorpusTest do
  use ExUnit.Case, async: true

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Loader
  alias ExVrp.Model

  test "entries/0 returns a non-empty list of entry structs" do
    entries = Corpus.entries()
    assert is_list(entries)
    assert entries != []
    assert Enum.all?(entries, &match?(%Corpus.Entry{}, &1))
  end

  test "every entry has the required fields populated" do
    for e <- Corpus.entries() do
      assert is_binary(e.id)
      assert e.variant in [:cvrp, :vrptw, :pcvrptw, :mtvrptwr, :production, :production_breaks]
      assert e.kind in [:vrplib, :etf]
      assert is_binary(e.path)
    end
  end

  test "entry ids are unique" do
    ids = Enum.map(Corpus.entries(), & &1.id)
    assert ids == Enum.uniq(ids)
  end

  test "every production instance also runs with breaks, from the same snapshot" do
    entries = Corpus.entries()
    production = for %{variant: :production} = e <- entries, into: %{}, do: {e.path, e.id}
    with_breaks = for %{variant: :production_breaks} = e <- entries, into: %{}, do: {e.path, e.id}

    assert Map.keys(with_breaks) == Map.keys(production)
    assert Enum.all?(with_breaks, fn {path, "prodbrk_" <> name} -> production[path] == "prod_" <> name end)
  end

  test "a break twin loads with limits between breaks on every vehicle type" do
    entry = Enum.find(Corpus.entries(), &(&1.variant == :production_breaks))
    model = Loader.load(entry)

    assert Enum.all?(model.vehicle_types, &(&1.break_duration > 0 and &1.max_drive_between_breaks != :infinity))
    assert Model.validate(model) == :ok
  end

  test "every literature file referenced by the corpus exists on disk" do
    for e <- Corpus.entries(), e.variant not in [:production, :production_breaks] do
      assert File.exists?(e.path), "missing corpus file: #{e.path}"
    end
  end

  test "bks/1 returns nil for an unknown id and a number-or-nil for a known id" do
    assert Corpus.bks("definitely-not-an-id") == nil
    first = hd(Corpus.entries())
    value = Corpus.bks(first.id)
    assert value == nil or is_number(value)
  end

  test "corpus now includes pcvrptw and mtvrptwr coverage" do
    variants = Corpus.entries() |> Enum.map(& &1.variant) |> Enum.uniq()
    assert :pcvrptw in variants
    assert :mtvrptwr in variants
  end
end
