defmodule ExVrp.DutyRule do
  @moduledoc """
  How long a duty period, the time between two rests, may last, how much of it
  may be driving, and how long each rest lasts: a driver's daily rest. Under
  EU 561/2006 that is at most 13 hours on duty, 9 of them driving, then a rest
  of 11 hours. Set it as a vehicle type's `:duty_rule`.

  `:max_duty` counts elapsed time, waiting included, except waiting before a
  period's first visit, which lengthens the rest. `:max_drive` bounds one
  period; the vehicle type's own `:max_drive` still bounds the whole route.
  The carries are what the driver did outside the route: duty and driving
  since their last rest, joining the route's first period, and duty after it
  ends, joining its last.

  Both limits default to `:infinity`. A rule with neither only sets how long
  a rest placed by hand (`:initial_routes`) lasts: the solver places rests
  only to keep a limit.

      iex> rule = ExVrp.DutyRule.new(max_duty: 780, max_drive: 540, rest_duration: 660)
      iex> {rule.max_duty, rule.max_drive, rule.duty_carry_in}
      {780, 540, 0}
  """

  @type t :: %__MODULE__{
          rest_duration: non_neg_integer(),
          max_duty: pos_integer() | :infinity,
          max_drive: pos_integer() | :infinity,
          duty_carry_in: non_neg_integer(),
          drive_carry_in: non_neg_integer(),
          duty_after_end: non_neg_integer()
        }

  defstruct rest_duration: 0,
            max_duty: :infinity,
            max_drive: :infinity,
            duty_carry_in: 0,
            drive_carry_in: 0,
            duty_after_end: 0

  @doc "Creates a duty rule from the fields above."
  @spec new(keyword()) :: t()
  def new(fields), do: struct!(__MODULE__, fields)

  @doc "Whether the rule limits its periods, so the solver places rests to keep it."
  @spec limits?(t() | nil) :: boolean()
  def limits?(%__MODULE__{max_duty: :infinity, max_drive: :infinity}), do: false
  def limits?(%__MODULE__{}), do: true
  def limits?(nil), do: false
end
