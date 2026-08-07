# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Range do
  @moduledoc """
  A continuous range of values of some inner type, with inclusive/exclusive bounds.

  The value representation for `Ash.Type.Range`. `bounds` follows Postgres range
  notation: the first character is the lower bound, the second the upper —
  `[` / `]` inclusive, `(` / `)` exclusive. A `nil` `lower`/`upper` is an
  unbounded (infinite) end. The default `:"[)"` (lower-inclusive, upper-exclusive)
  is the convention that lets adjacent ranges tile a timeline without overlap.
  """

  @type bounds :: :"[)" | :"[]" | :"()" | :"(]"

  @type t :: %__MODULE__{
          lower: term() | nil,
          upper: term() | nil,
          bounds: bounds()
        }

  defstruct lower: nil, upper: nil, bounds: :"[)"

  @valid_bounds [:"[)", :"[]", :"()", :"(]"]

  @doc "Whether the given atom is a valid bounds specifier."
  @spec valid_bounds?(term()) :: boolean()
  def valid_bounds?(bounds), do: bounds in @valid_bounds

  @doc "Whether the range's lower bound includes its own value (`[`)."
  @spec lower_inclusive?(t() | bounds()) :: boolean()
  def lower_inclusive?(%__MODULE__{bounds: bounds}), do: lower_inclusive?(bounds)
  def lower_inclusive?(bounds), do: bounds in [:"[)", :"[]"]

  @doc "Whether the range's upper bound includes its own value (`]`)."
  @spec upper_inclusive?(t() | bounds()) :: boolean()
  def upper_inclusive?(%__MODULE__{bounds: bounds}), do: upper_inclusive?(bounds)
  def upper_inclusive?(bounds), do: bounds in [:"(]", :"[]"]

  @doc """
  Whether the range contains no points.

  A bounded range is empty when its lower bound is above its upper, or when the two
  are equal and either bound excludes the value: `[5,5)` and `(5,5]` are empty,
  `[5,5]` is the single point `5`. An unbounded end is never empty.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{lower: lower, upper: upper, bounds: bounds})
      when not is_nil(lower) and not is_nil(upper) do
    cond do
      Comp.less_than?(upper, lower) -> true
      Comp.equal?(lower, upper) -> not (lower_inclusive?(bounds) and upper_inclusive?(bounds))
      true -> false
    end
  end

  def empty?(%__MODULE__{}), do: false

  @doc """
  Whether the range holds `value`.

  An unbounded end holds everything beyond it, and an empty range holds nothing.
  Each bound is compared with `Comp`, so an inner type behaves inside a range as
  it does outside one, and a bound that excludes its own value (`(` or `)`) is
  not held.
  """
  @spec contains?(t(), term()) :: boolean()
  def contains?(%__MODULE__{} = range, value) do
    not empty?(range) and above_lower?(range, value) and below_upper?(range, value)
  end

  defp above_lower?(%{lower: nil}, _value), do: true

  defp above_lower?(range, value) do
    case Comp.compare(value, range.lower) do
      :gt -> true
      :eq -> lower_inclusive?(range)
      :lt -> false
    end
  end

  defp below_upper?(%{upper: nil}, _value), do: true

  defp below_upper?(range, value) do
    case Comp.compare(value, range.upper) do
      :lt -> true
      :eq -> upper_inclusive?(range)
      :gt -> false
    end
  end

  @doc """
  Compares two ranges by lower bound then upper, as Postgres orders them.

  Empty sorts below everything, an unbounded lower is `-∞` and an unbounded upper
  `+∞`. Where two bounds share a value the earlier boundary sorts first: `[1` starts
  at `1` where `(1` starts after it, and `5)` ends before `5` where `5]` ends at it.
  Bounds are compared with `Comp`, so an inner type orders inside a range as it does
  outside one.

  Emptiness is derived from the bounds, so an empty range that lost them in a data
  layer round trip reads as unbounded.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = left, %__MODULE__{} = right) do
    case {empty?(left), empty?(right)} do
      {true, true} -> :eq
      {true, false} -> :lt
      {false, true} -> :gt
      {false, false} -> compare_bounds(left, right)
    end
  end

  defp compare_bounds(left, right) do
    with :eq <- compare_lower(left, right) do
      compare_upper(left, right)
    end
  end

  defp compare_lower(%{lower: nil}, %{lower: nil}), do: :eq
  defp compare_lower(%{lower: nil}, _right), do: :lt
  defp compare_lower(_left, %{lower: nil}), do: :gt

  defp compare_lower(left, right) do
    with :eq <- Comp.compare(left.lower, right.lower) do
      earlier(lower_inclusive?(left), lower_inclusive?(right))
    end
  end

  defp compare_upper(%{upper: nil}, %{upper: nil}), do: :eq
  defp compare_upper(%{upper: nil}, _right), do: :gt
  defp compare_upper(_left, %{upper: nil}), do: :lt

  defp compare_upper(left, right) do
    with :eq <- Comp.compare(left.upper, right.upper) do
      earlier(not upper_inclusive?(left), not upper_inclusive?(right))
    end
  end

  # The boundary sitting earlier on the line sorts first.
  defp earlier(same, same), do: :eq
  defp earlier(true, false), do: :lt
  defp earlier(false, true), do: :gt
end

import Ash.Type.Comparable

defcomparable left :: Ash.Range, right :: Ash.Range do
  Ash.Range.compare(left, right)
end
