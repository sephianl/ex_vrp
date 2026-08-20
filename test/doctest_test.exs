defmodule ExVrp.DoctestTest do
  use ExUnit.Case, async: true

  doctest ExVrp.Client
  doctest ExVrp.ClientGroup
  doctest ExVrp.Depot
  doctest ExVrp.NeighbourhoodParams
  doctest ExVrp.PerturbationManager
  doctest ExVrp.VehicleType
end
