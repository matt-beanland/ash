# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Resource.Transformers.AddPeriodAttribute do
  # Adds or checks the period attribute of a temporal resource
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    if Ash.Resource.Info.temporal?(dsl_state) do
      add_or_check(dsl_state)
    else
      {:ok, dsl_state}
    end
  end

  defp add_or_check(dsl_state) do
    attribute_name = Ash.Resource.Info.temporal_attribute(dsl_state)
    module = Transformer.get_persisted(dsl_state, :module)

    case Ash.Resource.Info.attribute(dsl_state, attribute_name) do
      nil ->
        Ash.Resource.Builder.add_attribute(dsl_state, attribute_name, Ash.Type.Range,
          allow_nil?: false,
          generated?: true,
          constraints: [inner_type: :datetime, bounds: :inclusive_exclusive]
        )

      attribute ->
        check(attribute, module)
        {:ok, mark_generated(dsl_state, attribute)}
    end
  end

  # A period is never action input, so its value can only come from the data layer
  # at the instant of the write — which is what `generated?` means. That follows
  # from declaring the resource temporal, so temporal sets it rather than asking a
  # declared attribute to restate it. Without it the period is required but
  # unsettable, and every create fails with "attribute ... is required".
  defp mark_generated(dsl_state, %{generated?: true}), do: dsl_state

  defp mark_generated(dsl_state, attribute) do
    Transformer.replace_entity(
      dsl_state,
      [:attributes],
      %{attribute | generated?: true},
      &(&1.name == attribute.name)
    )
  end

  # The attribute is the single source of truth for its own type and bounds; only
  # what temporal itself requires of it is checked here.
  defp check(attribute, module) do
    cond do
      attribute.type != Ash.Type.Range ->
        raise Spark.Error.DslError,
          module: module,
          path: [:attributes, attribute.name],
          message: """
          Expected the attribute #{attribute.name} to be an `Ash.Type.Range`, since it is this \
          resource's period. Got #{inspect(attribute.type)}.
          """

      Ash.Range.notation(attribute.constraints[:bounds]) != :"[)" ->
        raise Spark.Error.DslError,
          module: module,
          path: [:attributes, attribute.name],
          message: """
          Expected the attribute #{attribute.name} to constrain its `bounds` to \
          `:inclusive_exclusive`. Periods must all use one form for adjacent ones to meet \
          without overlapping or leaving a gap, and this is the form Postgres and SQL:2011 \
          application-time periods use. #{bounds_got(attribute)}.
          """

      attribute.allow_nil? ->
        raise Spark.Error.DslError,
          module: module,
          path: [:attributes, attribute.name],
          message: """
          Expected the attribute #{attribute.name} not to be `allow_nil? true`. A row of a \
          temporal resource is valid over some period, and a row valid over no period cannot \
          be read at any point in time.
          """

      true ->
        :ok
    end
  end

  # Omitting the constraint and setting it to something else are different
  # mistakes, and "got nil" reads like the second when it is usually the first.
  defp bounds_got(%{constraints: constraints}) do
    case constraints[:bounds] do
      nil -> "It declares no bounds constraint"
      bounds -> "Got #{inspect(bounds)}"
    end
  end
end
