defmodule ExVrp.Literature.RunSettings do
  @moduledoc """
  How a literature run solves its instances. `passmark` is the run machine's single-thread
  PassMark score and `budget_scale` shortens every budget for quick checks; results are
  only comparable with PyVRP's published numbers at the machine's real score and scale 1.
  """

  @type t :: %__MODULE__{
          seeds: [integer()],
          passmark: pos_integer() | nil,
          budget_scale: number(),
          out_path: String.t(),
          workers: pos_integer()
        }

  @enforce_keys [:seeds, :passmark, :budget_scale, :out_path, :workers]
  defstruct [:seeds, :passmark, :budget_scale, :out_path, :workers]
end
