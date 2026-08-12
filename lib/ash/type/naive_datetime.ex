# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Type.NaiveDatetime do
  @constraints [
    precision: [
      type: {:one_of, [:microsecond, :second]},
      default: :second
    ]
  ]

  @moduledoc """
  Represents a Naive datetime, with configurable precision.

  A builtin type that can be referenced via `:naive_datetime`

  ### Constraints

  #{Spark.Options.docs(@constraints)}
  """
  use Ash.Type

  @impl true
  def constraints, do: @constraints

  @impl true
  def init(constraints) do
    {precision, constraints} = Keyword.pop(constraints, :precision)
    precision = precision || :second
    {:ok, [{:precision, precision} | constraints]}
  end

  @impl true
  def storage_type([{:precision, :microsecond} | _]), do: :naive_datetime_usec
  def storage_type(_constraints), do: :naive_datetime

  @impl true
  def generator(_constraints) do
    # Waiting on blessed date/datetime generators in stream data
    # https://github.com/whatyouhide/stream_data/pull/161/files
    StreamData.constant(NaiveDateTime.utc_now())
  end

  @impl true
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(
        %NaiveDateTime{microsecond: {_, _} = microseconds} = datetime,
        [{:precision, :second} | _] = constraints
      )
      when microseconds != {0, 0} do
    cast_input(%{datetime | microsecond: {0, 0}}, constraints)
  end

  def cast_input(
        %NaiveDateTime{microsecond: {0, 0}} = datetime,
        [{:precision, :microsecond} | _] = constraints
      ) do
    cast_input(%{datetime | microsecond: {0, 6}}, constraints)
  end

  def cast_input(value, constraints) do
    Ecto.Type.cast(storage_type(constraints), value)
  end

  @impl true
  def matches_type?(%NaiveDateTime{microsecond: {usec, _}}, constraints) when usec != 0 do
    Keyword.get(constraints, :precision, :second) == :microsecond
  end

  def matches_type?(%NaiveDateTime{}, _), do: true
  def matches_type?(_, _), do: false

  @impl true
  def cast_atomic(new_value, _constraints) do
    {:atomic, new_value}
  end

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(value, constraints) when is_binary(value) do
    cast_input(value, constraints)
  end

  def cast_stored(value, constraints) do
    Ecto.Type.load(storage_type(constraints), value)
  end

  @impl true

  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(value, constraints) do
    Ecto.Type.dump(storage_type(constraints), value)
  end
end

import Comp

defcomparable left :: NaiveDateTime, right :: NaiveDateTime do
  NaiveDateTime.compare(left, right)
end
