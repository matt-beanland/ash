# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Type.RangeTest do
  use ExUnit.Case, async: true

  alias Ash.Range

  {:ok, constraints} =
    Ash.Type.init(Ash.Type.Range,
      inner_type: :datetime,
      inner_constraints: [precision: :microsecond]
    )

  {:ok, date_constraints} = Ash.Type.init(Ash.Type.Range, inner_type: :date)
  @constraints constraints
  @date_constraints date_constraints

  @lower ~U[2026-01-01 00:00:00.000000Z]
  @middle ~U[2026-01-15 00:00:00.000000Z]
  @upper ~U[2026-02-01 00:00:00.000000Z]
  @latest ~U[2026-03-01 00:00:00.000000Z]

  test "the :range short name resolves to Ash.Type.Range" do
    assert Ash.Type.get_type(:range) == Ash.Type.Range
  end

  test "storage_type is the logical :range (data layer chooses the concrete type)" do
    assert Ash.Type.Range.storage_type(@constraints) == :range
    assert Ash.Type.Range.storage_type(@date_constraints) == :range
  end

  test "generator/1 produces ordered ranges of the inner type" do
    {:ok, int_constraints} =
      Ash.Type.init(Ash.Type.Range, inner_type: :integer, inner_constraints: [min: 0, max: 100])

    int_constraints
    |> Ash.Type.Range.generator()
    |> Enum.take(50)
    |> Enum.each(fn %Range{lower: lower, upper: upper, bounds: :"[)"} ->
      assert is_integer(lower) and lower in 0..100
      assert is_integer(upper) and upper in 0..100
      assert lower <= upper
    end)
  end

  test "cast_input from an Ash.Range struct casts the bounds via the inner type" do
    assert {:ok, %Range{lower: @lower, upper: @upper, bounds: :"[)"}} =
             Ash.Type.cast_input(
               Ash.Type.Range,
               %Range{lower: @lower, upper: @upper},
               @constraints
             )
  end

  test "cast_input from a {lower, upper} tuple defaults bounds to [)" do
    assert {:ok, %Range{lower: @lower, upper: @upper, bounds: :"[)"}} =
             Ash.Type.cast_input(Ash.Type.Range, {@lower, @upper}, @constraints)
  end

  test "a nil bound is an unbounded end" do
    assert {:ok, %Range{lower: @lower, upper: nil}} =
             Ash.Type.cast_input(Ash.Type.Range, %Range{lower: @lower, upper: nil}, @constraints)
  end

  test "round-trips through dump_to_native and cast_stored" do
    {:ok, range} =
      Ash.Type.cast_input(Ash.Type.Range, %Range{lower: @lower, upper: @upper}, @constraints)

    {:ok, native} = Ash.Type.dump_to_native(Ash.Type.Range, range, @constraints)
    assert %{lower: _, upper: _, bounds: :"[)"} = native

    assert {:ok, ^range} = Ash.Type.cast_stored(Ash.Type.Range, native, @constraints)
  end

  test "apply_constraints rejects a lower bound greater than the upper" do
    {:ok, range} =
      Ash.Type.cast_input(Ash.Type.Range, %Range{lower: @upper, upper: @lower}, @constraints)

    assert {:error, _} = Ash.Type.apply_constraints(Ash.Type.Range, range, @constraints)
  end

  describe "ordering" do
    # Every expectation below is the order PostgreSQL returns for the equivalent
    # `tstzrange` values, the type a `:datetime` range maps to. tstzrange is
    # continuous, so bounds survive as written and inclusivity is observable — a
    # discrete type like the `int8range` behind an `:integer` range canonicalises
    # to `[)` first and hides it.
    @ordered [
      %Range{lower: @upper, upper: @upper, bounds: :"[)"},
      %Range{lower: nil, upper: @upper, bounds: :"()"},
      %Range{lower: nil, upper: @upper, bounds: :"(]"},
      %Range{lower: nil, upper: nil, bounds: :"()"},
      %Range{lower: @lower, upper: @upper, bounds: :"[)"},
      %Range{lower: @lower, upper: @upper, bounds: :"[]"},
      %Range{lower: @lower, upper: nil, bounds: :"[)"},
      %Range{lower: @lower, upper: @upper, bounds: :"()"},
      %Range{lower: @lower, upper: @upper, bounds: :"(]"},
      %Range{lower: @lower, upper: nil, bounds: :"()"}
    ]

    test "sorts as Postgres does" do
      assert @ordered |> Enum.shuffle() |> Enum.sort(Range) == @ordered
    end

    # A short period nested inside a longer one, where ordering by lower and
    # ordering by upper disagree. Without a comparator the generic fallback
    # compares the structs as maps, whose key order puts `upper` first, so this
    # came back reversed from what Postgres returns for the same two ranges.
    test "a nested range orders by lower, not upper" do
      short = %Range{lower: @middle, upper: @upper, bounds: :"[)"}
      long = %Range{lower: @lower, upper: @latest, bounds: :"[)"}

      assert Range.compare(short, long) == :gt
      assert Enum.sort([short, long], Range) == [long, short]
    end

    test "orders by lower bound before upper" do
      assert Range.compare(
               %Range{lower: @lower, upper: @upper, bounds: :"[)"},
               %Range{lower: @upper, upper: @upper, bounds: :"[]"}
             ) == :lt
    end

    test "an unbounded lower is below every value, an unbounded upper above" do
      assert Range.compare(
               %Range{lower: nil, upper: @upper},
               %Range{lower: @lower, upper: @upper}
             ) == :lt

      assert Range.compare(
               %Range{lower: @lower, upper: nil},
               %Range{lower: @lower, upper: @upper}
             ) == :gt
    end

    test "the wider bound sorts first when two bounds hold the same value" do
      assert Range.compare(
               %Range{lower: @lower, upper: @upper, bounds: :"[)"},
               %Range{lower: @lower, upper: @upper, bounds: :"()"}
             ) == :lt

      assert Range.compare(
               %Range{lower: @lower, upper: @upper, bounds: :"[)"},
               %Range{lower: @lower, upper: @upper, bounds: :"[]"}
             ) == :lt
    end

    test "the empty range sorts below everything and equals itself" do
      empty = %Range{lower: @lower, upper: @lower, bounds: :"[)"}
      other_empty = %Range{lower: @upper, upper: @upper, bounds: :"(]"}

      assert Range.compare(empty, other_empty) == :eq
      assert Range.compare(empty, %Range{lower: nil, upper: nil, bounds: :"()"}) == :lt
    end

    test "orders date ranges through Comp, not term order" do
      earlier = %Range{lower: ~D[2019-01-01], upper: ~D[2019-12-31], bounds: :"[]"}
      later = %Range{lower: ~D[2020-01-01], upper: ~D[2020-12-31], bounds: :"[)"}

      # Term order compares `bounds` before `lower`, which puts these the wrong
      # way around; `Comp` must not inherit that.
      assert Enum.sort([later, earlier]) == [later, earlier]
      assert Comp.compare(later, earlier) == :gt
      assert Enum.sort([later, earlier], Range) == [earlier, later]
    end

    test "Comp routes through the comparable rather than falling back" do
      assert Comparable.impl_for(%Comparable.Type.Ash.Range.To.Ash.Range{
               left: %Range{},
               right: %Range{}
             })
    end
  end

  describe "empty?/1" do
    test "a bounded range with no points is empty" do
      assert Range.empty?(%Range{lower: 5, upper: 5, bounds: :"[)"})
      assert Range.empty?(%Range{lower: 5, upper: 5, bounds: :"(]"})
      assert Range.empty?(%Range{lower: 9, upper: 5, bounds: :"[)"})
    end

    test "a single point and any unbounded end are not empty" do
      refute Range.empty?(%Range{lower: 5, upper: 5, bounds: :"[]"})
      refute Range.empty?(%Range{lower: nil, upper: nil, bounds: :"()"})
      refute Range.empty?(%Range{lower: 1, upper: nil, bounds: :"[)"})
    end
  end

  describe "contains?/2" do
    test "a bounded range holds values between its bounds" do
      range = %Ash.Range{lower: 1, upper: 5, bounds: :"[)"}

      refute Ash.Range.contains?(range, 0)
      assert Ash.Range.contains?(range, 1)
      assert Ash.Range.contains?(range, 4)
      refute Ash.Range.contains?(range, 5)
    end

    test "a bound holds its own value only when inclusive" do
      assert Ash.Range.contains?(%Ash.Range{lower: 1, upper: 5, bounds: :"[]"}, 5)
      refute Ash.Range.contains?(%Ash.Range{lower: 1, upper: 5, bounds: :"()"}, 1)
      assert Ash.Range.contains?(%Ash.Range{lower: 1, upper: 5, bounds: :"(]"}, 5)
      refute Ash.Range.contains?(%Ash.Range{lower: 1, upper: 5, bounds: :"(]"}, 1)
    end

    test "an unbounded end holds everything beyond it" do
      assert Ash.Range.contains?(%Ash.Range{lower: nil, upper: 5}, -1_000)
      assert Ash.Range.contains?(%Ash.Range{lower: 1, upper: nil}, 1_000)
      assert Ash.Range.contains?(%Ash.Range{lower: nil, upper: nil}, 0)
    end

    test "an empty range holds nothing" do
      refute Ash.Range.contains?(%Ash.Range{lower: 5, upper: 5, bounds: :"[)"}, 5)
      refute Ash.Range.contains?(%Ash.Range{lower: 9, upper: 5}, 7)
    end

    test "holds datetimes by Comp, not by term order" do
      range = %Ash.Range{
        lower: ~U[2026-01-31 00:00:00Z],
        upper: ~U[2026-03-01 00:00:00Z],
        bounds: :"[)"
      }

      assert Ash.Range.contains?(range, ~U[2026-02-01 00:00:00Z])
      refute Ash.Range.contains?(range, ~U[2026-03-02 00:00:00Z])
    end
  end

  describe "bounds names" do
    # Names are an alternative spelling, not a replacement: whichever is given,
    # the struct carries the notation, so nothing matching on `bounds` changes.
    test "a name casts to its notation" do
      for {name, notation} <- [
            inclusive_exclusive: :"[)",
            inclusive_inclusive: :"[]",
            exclusive_exclusive: :"()",
            exclusive_inclusive: :"(]"
          ] do
        {:ok, range} =
          Ash.Type.cast_input(
            Ash.Type.Range,
            %{lower: @lower, upper: @upper, bounds: name},
            @constraints
          )

        assert range.bounds == notation
      end
    end

    test "notation is unchanged, so existing callers are unaffected" do
      {:ok, range} =
        Ash.Type.cast_input(
          Ash.Type.Range,
          %{lower: @lower, upper: @upper, bounds: :"[]"},
          @constraints
        )

      assert range.bounds == :"[]"
    end

    test "both spellings answer the inclusivity questions identically" do
      assert Range.lower_inclusive?(:inclusive_exclusive) == Range.lower_inclusive?(:"[)")
      assert Range.upper_inclusive?(:exclusive_inclusive) == Range.upper_inclusive?(:"(]")
      refute Range.upper_inclusive?(:inclusive_exclusive)
      assert Range.upper_inclusive?(:inclusive_inclusive)
    end

    test "valid_bounds?/1 accepts either spelling and rejects anything else" do
      assert Range.valid_bounds?(:"[)")
      assert Range.valid_bounds?(:inclusive_exclusive)
      refute Range.valid_bounds?(:half_open)
    end
  end

  describe "the bounds constraint" do
    test "omitting it admits any bounds" do
      for bounds <- Range.valid_bounds() do
        assert {:ok, _} =
                 Ash.Type.cast_input(
                   Ash.Type.Range,
                   %{lower: @lower, upper: @upper, bounds: bounds},
                   @constraints
                 )
                 |> then(fn {:ok, r} ->
                   Ash.Type.apply_constraints(Ash.Type.Range, r, @constraints)
                 end)
      end
    end

    test "a permitted form passes and a refused one fails" do
      {:ok, constraints} =
        Ash.Type.init(Ash.Type.Range, inner_type: :datetime, bounds: :inclusive_exclusive)

      {:ok, ok} =
        Ash.Type.cast_input(
          Ash.Type.Range,
          %{lower: @lower, upper: @upper, bounds: :"[)"},
          constraints
        )

      assert {:ok, _} = Ash.Type.apply_constraints(Ash.Type.Range, ok, constraints)

      {:ok, bad} =
        Ash.Type.cast_input(
          Ash.Type.Range,
          %{lower: @lower, upper: @upper, bounds: :"[]"},
          constraints
        )

      assert {:error, _} = Ash.Type.apply_constraints(Ash.Type.Range, bad, constraints)
    end

    test "the constraint and the value may use different spellings" do
      # Declared by name, value given as notation.
      {:ok, constraints} =
        Ash.Type.init(Ash.Type.Range, inner_type: :datetime, bounds: :inclusive_exclusive)

      {:ok, range} =
        Ash.Type.cast_input(
          Ash.Type.Range,
          %{lower: @lower, upper: @upper, bounds: :"[)"},
          constraints
        )

      assert {:ok, _} = Ash.Type.apply_constraints(Ash.Type.Range, range, constraints)

      # Declared as notation, value given by name.
      {:ok, notation_constraints} =
        Ash.Type.init(Ash.Type.Range, inner_type: :datetime, bounds: :"[)")

      {:ok, named} =
        Ash.Type.cast_input(
          Ash.Type.Range,
          %{lower: @lower, upper: @upper, bounds: :inclusive_exclusive},
          notation_constraints
        )

      assert {:ok, _} = Ash.Type.apply_constraints(Ash.Type.Range, named, notation_constraints)
    end

    test "the constraint is a single form, not a set" do
      # A set would permit mixing within one attribute, and mixing is what makes
      # meeting depend on position rather than on the range itself.
      assert {:error, _} =
               Ash.Type.init(Ash.Type.Range,
                 inner_type: :datetime,
                 bounds: [:inclusive_exclusive, :inclusive_inclusive]
               )
    end

    test "a discrete range is refused rather than canonicalised" do
      # [1,4] and [1,5) are the same set of integers. Postgres would convert;
      # this refuses, which is a divergence worth knowing about.
      {:ok, constraints} =
        Ash.Type.init(Ash.Type.Range, inner_type: :integer, bounds: :inclusive_exclusive)

      {:ok, equivalent} =
        Ash.Type.cast_input(Ash.Type.Range, %{lower: 1, upper: 4, bounds: :"[]"}, constraints)

      assert {:error, _} = Ash.Type.apply_constraints(Ash.Type.Range, equivalent, constraints)
    end
  end
end
