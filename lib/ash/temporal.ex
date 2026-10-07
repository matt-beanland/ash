# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Temporal do
  @moduledoc """
  Resolves `as_of` into the point of time or period that the data layer stores.

  On a [temporal resource](/documentation/topics/advanced/temporal-resources.md) every
  version of a record is valid for a period of datetimes. You can provide a `DateTime`, or
  `:now` for resolution by the data layer.

  ```elixir
  # a read resolves as_of a point in time
  Ash.Temporal.resolve_read_as_of(query.as_of)

  # a write resolves a period beginning at the point,
  # and extending forever unless a later write closes it
  {:ok, instant} = Ash.Temporal.write_instant(resource, :now)
  {:ok, period} = Ash.Temporal.write_period(resource, :now)
  ```

  The write functions return a `DateTime` cast to the precision the resource's period
  declares, and to the start of a period of its resolution.

  A write that provides no `as_of` takes effect now. Data layers provide `:now` for this.
  """

  @temporal_safe_modules Application.compile_env(:ash, :temporal_safe_modules, [])

  @typedoc "An `as_of` as a caller may give it, before it is resolved."
  @type as_of :: :now | {:period, :now | term()} | term() | nil

  @doc """
  Casts the `as_of` of a write to a temporal resource into the type its periods are built
  from, applying the precision that type declares.

  An instant or `:now` becomes an instant (see `write_instant/2`), and a range or
  `{:period, instant}` becomes a period (see `write_period/2`). Anything that can't be cast, and any `as_of` of a resource that
  isn't temporal, is returned unchanged.
  """
  @spec cast_write_as_of(Ash.Resource.t(), as_of()) :: term()
  def cast_write_as_of(_resource, nil), do: nil

  def cast_write_as_of(resource, as_of) do
    if Ash.Resource.Info.temporal?(resource) do
      result =
        if period?(as_of),
          do: write_period(resource, as_of),
          else: write_instant(resource, as_of)

      case result do
        {:ok, cast} -> cast
        :error -> as_of
      end
    else
      as_of
    end
  end

  @doc """
  Checks the `as_of` of a write to a temporal resource, casting it as `cast_write_as_of/2` does.

  A range or `{:period, instant}` must cast to the resource's period, and satisfy its
  constraints. An instant must
  cast to the type the resource's periods are built from, and lie within the period's
  limits; for a create it opens a period with no end, which must satisfy the period's
  constraints. Returns the cast `as_of`, or an `Ash.Error.Changes.InvalidAsOf` saying why
  it is refused. Any `as_of` of a resource that isn't temporal is returned unchanged.

  ### Options

  * `:action_type` - the type of the write, `:create`, `:update` or `:destroy`.
  * `:implied?` - whether the `as_of` is the default `:now` of a write given none.
  * `:period_set?` - whether the write sets the period itself, as a seed does, so that an
    instant only times it and is not checked against the period's limits.
  """
  @spec check_write_as_of(Ash.Resource.t(), as_of(), Keyword.t()) ::
          {:ok, term()} | {:error, Exception.t()}
  def check_write_as_of(resource, as_of, opts \\ [])
  def check_write_as_of(_resource, nil, _opts), do: {:ok, nil}

  def check_write_as_of(resource, as_of, opts) do
    if Ash.Resource.Info.temporal?(resource) do
      do_check_write_as_of(resource, as_of, opts)
    else
      {:ok, as_of}
    end
  end

  defp do_check_write_as_of(resource, as_of, opts) do
    if period?(as_of),
      do: check_write_period(resource, as_of, opts),
      else: check_write_instant(resource, as_of, opts)
  end

  defp check_write_period(resource, as_of, opts) do
    %{type: type, constraints: constraints} = Ash.Resource.Info.temporal_period(resource)

    with {:ok, period} <- cast_or_refuse(resource, as_of, write_period(resource, as_of), opts),
         :ok <- satisfies(resource, as_of, type, period, constraints, opts) do
      {:ok, period}
    end
  end

  defp check_write_instant(resource, as_of, opts) do
    %{type: type, constraints: constraints} = Ash.Resource.Info.temporal_period(resource)

    with {:ok, instant} <- cast_or_refuse(resource, as_of, write_instant(resource, as_of), opts),
         :ok <- unless_period_set(opts, &within_limits(resource, as_of, instant, constraints, &1)),
         :ok <-
           unless_period_set(
             opts,
             &opens_a_valid_period(resource, as_of, instant, type, constraints, &1)
           ) do
      {:ok, instant}
    end
  end

  defp unless_period_set(opts, check) do
    if Keyword.get(opts, :period_set?, false), do: :ok, else: check.(opts)
  end

  defp cast_or_refuse(_resource, _as_of, {:ok, cast}, _opts), do: {:ok, cast}

  defp cast_or_refuse(resource, as_of, :error, opts) do
    {:error,
     invalid_as_of(
       resource,
       as_of,
       "an `as_of` is an instant of the resource's period, `:now`, a range, or `{:period, instant}`",
       [],
       opts
     )}
  end

  defp satisfies(resource, as_of, type, period, constraints, opts) do
    case Ash.Type.apply_constraints(type, period, constraints) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, constraint_error(resource, as_of, error, opts)}
    end
  end

  # An update or destroy writes within the version it splits, which already holds within the limits.
  defp within_limits(resource, as_of, instant, constraints, opts) do
    lower = constraints[:lower][:limit]
    upper = constraints[:upper][:limit]

    cond do
      lower && Comp.less_than?(instant, lower) ->
        {:error,
         invalid_as_of(
           resource,
           as_of,
           "the period starts at %{limit} at the earliest",
           [limit: lower],
           opts
         )}

      upper && not Comp.less_than?(instant, upper) ->
        {:error,
         invalid_as_of(
           resource,
           as_of,
           "the period ends at %{limit} at the latest",
           [limit: upper],
           opts
         )}

      true ->
        :ok
    end
  end

  # A create as of an instant opens a period with no end.
  defp opens_a_valid_period(resource, as_of, instant, type, constraints, opts) do
    if opts[:action_type] == :create do
      if constraints[:upper][:limit] do
        {:error,
         invalid_as_of(
           resource,
           as_of,
           "a create as of an instant has no end, and the period ends at %{limit} at the latest; write over a range ending at `:end`",
           [limit: constraints[:upper][:limit]],
           opts
         )}
      else
        satisfies(resource, as_of, type, %Ash.Range{lower: instant}, constraints, opts)
      end
    else
      :ok
    end
  end

  defp constraint_error(resource, as_of, [{key, _} | _] = error, opts) when is_atom(key),
    do: invalid_as_of(resource, as_of, error[:message] || "invalid", error[:vars] || [], opts)

  defp constraint_error(resource, as_of, [first | _], opts),
    do: constraint_error(resource, as_of, first, opts)

  defp constraint_error(resource, as_of, message, opts) when is_binary(message),
    do: invalid_as_of(resource, as_of, message, [], opts)

  defp constraint_error(resource, as_of, _error, opts),
    do: invalid_as_of(resource, as_of, "invalid", [], opts)

  defp invalid_as_of(resource, as_of, message, vars, opts) do
    Ash.Error.Changes.InvalidAsOf.exception(
      resource: resource,
      as_of: as_of,
      message: message,
      vars: vars,
      implied?: Keyword.get(opts, :implied?, false)
    )
  end

  @doc """
  Resolves the `as_of` a write takes effect at.

  `:now` resolves to the current time. A range resolves to its lower bound. Anything else is
  returned unchanged. `nil` means no particular time was provided.
  """
  @spec resolve_write_as_of(as_of()) :: term() | nil
  def resolve_write_as_of(:now), do: DateTime.utc_now()
  def resolve_write_as_of(%Ash.Range{lower: nil}), do: nil
  def resolve_write_as_of(%Ash.Range{lower: lower}), do: resolve_write_as_of(lower)
  def resolve_write_as_of(other), do: other

  @doc """
  Resolves the `as_of` a read answers at.

  `:now` resolves to the current time, and a `DateTime` is that instant. `nil` means no
  particular time was provided. Anything else, such as a range, `{:period, instant}` or a
  `Date`, raises `Ash.Error.Query.AsOfNotAnInstant`.
  """
  @spec resolve_read_as_of(as_of()) :: DateTime.t() | nil
  def resolve_read_as_of(:now), do: DateTime.utc_now()
  def resolve_read_as_of(nil), do: nil
  def resolve_read_as_of(%DateTime{} = as_of), do: as_of

  def resolve_read_as_of(as_of) do
    raise Ash.Error.Query.AsOfNotAnInstant.exception(resource: nil, as_of: as_of)
  end

  @doc """
  Whether a change, validation or preparation module declares itself safe to run on a
  temporal resource, for the given options.

  Every action on a temporal resource runs "as of" a point in time, so anything that
  runs as part of one must not assume it is happening now. A module declares that it
  meets that bar with the `temporal_safe?/1` callback of its behaviour
  (`c:Ash.Resource.Change.temporal_safe?/1`, `c:Ash.Resource.Validation.temporal_safe?/1`,
  `c:Ash.Resource.Preparation.temporal_safe?/1`). A module that does not define it is
  not temporal safe.

  Modules from packages that don't declare it yet can be listed as temporal safe in
  config:

      config :ash, :temporal_safe_modules, [SomePackage.Changes.DoesThing]
  """
  @spec temporal_safe?(module(), Keyword.t()) :: boolean()
  def temporal_safe?(module, opts) do
    Enum.member?(@temporal_safe_modules, module) or
      (Code.ensure_loaded?(module) and function_exported?(module, :temporal_safe?, 1) and
         module.temporal_safe?(opts) == true)
  end

  @doc false
  # Raises `Ash.Error.Framework.NotTemporalSafe` when `module` is about to run as part of
  # an action on a temporal resource without having declared itself temporal safe.
  # `subject` is the changeset, query or action input being acted on (or a batch of
  # changesets). Called from the `Ash.Resource.Change`/`Validation`/`Preparation`
  # dispatchers, so every path that runs one of these is covered.
  @spec assert_temporal_safe!(
          :change | :validation | :preparation,
          module(),
          Keyword.t(),
          Ash.Changeset.t()
          | Ash.Query.t()
          | Ash.ActionInput.t()
          | [Ash.Changeset.t()]
          | Enumerable.t(Ash.Changeset.t())
        ) :: :ok
  def assert_temporal_safe!(type, module, opts, [subject | _]),
    do: assert_temporal_safe!(type, module, opts, subject)

  def assert_temporal_safe!(_type, _module, _opts, []), do: :ok

  def assert_temporal_safe!(_type, _module, _opts, %Stream{}), do: :ok

  def assert_temporal_safe!(type, module, opts, %{resource: resource} = subject) do
    if Ash.Resource.Info.temporal?(resource) and not temporal_safe?(module, opts) do
      raise Ash.Error.to_error_class(
              Ash.Error.Framework.NotTemporalSafe.exception(
                resource: resource,
                action: Map.get(subject, :action),
                module: module,
                type: type
              )
            )
    end

    :ok
  end

  @doc """
  Resolves the period a write is valid for.

  The value comes back cast to the resource's period. A range is that period, and
  `{:period, instant}` the period holding just the instant, one unit of the period's
  precision long (see `Ash.Type.Range.period/2`). Otherwise the period begins where the write
  takes effect and extends forever unless a later write closes it.
  """
  @spec write_period(Ash.Resource.t(), as_of()) :: {:ok, Ash.Range.t()} | :error
  def write_period(resource, %Ash.Range{} = as_of) do
    with %{type: type, constraints: constraints} <- Ash.Resource.Info.temporal_period(resource),
         bounded = resolve_bounds(as_of),
         {:ok, period} <- Ash.Type.cast_input(type, bounded, constraints) do
      {:ok, period}
    else
      _ -> :error
    end
  end

  def write_period(resource, {:period, instant})
      when instant == :now or is_struct(instant, DateTime) do
    with %{constraints: constraints} <- Ash.Resource.Info.temporal_period(resource),
         {:ok, raw} <- raw_instant(instant),
         {:ok, period} <- Ash.Type.Range.period(raw, constraints) do
      {:ok, period}
    else
      _ -> :error
    end
  end

  def write_period(_resource, {:period, _instant}), do: :error

  def write_period(resource, as_of) do
    case write_instant(resource, as_of) do
      {:ok, instant} -> {:ok, %Ash.Range{lower: instant}}
      :error -> :error
    end
  end

  # A bound reads `:now` off the same clock a bare `:now` does, so the two spellings agree.
  defp resolve_bounds(%Ash.Range{} = as_of) do
    %{as_of | lower: resolve_bound(as_of.lower), upper: resolve_bound(as_of.upper)}
  end

  defp resolve_bound(:now), do: DateTime.utc_now()
  defp resolve_bound(bound), do: bound

  @doc """
  Resolves the point where a write first takes effect.

  The value comes back cast to whatever precision the resource's period declares, and at the
  start of the period of its resolution holding it (see `Ash.Type.Range.period/2`).
  """
  @spec write_instant(Ash.Resource.t(), as_of()) :: {:ok, DateTime.t()} | :error
  def write_instant(resource, as_of) do
    with %{constraints: constraints} <- Ash.Resource.Info.temporal_period(resource),
         {:ok, raw} <- raw_instant(as_of),
         {:ok, %Ash.Range{lower: instant}} <- Ash.Type.Range.period(raw, constraints) do
      {:ok, instant}
    else
      _ -> :error
    end
  end

  defp raw_instant(%DateTime{} = as_of), do: {:ok, as_of}
  defp raw_instant(:now), do: {:ok, DateTime.utc_now()}
  defp raw_instant(%Ash.Range{lower: nil}), do: :error
  defp raw_instant(%Ash.Range{lower: lower}), do: raw_instant(lower)
  defp raw_instant(_as_of), do: :error

  defp period?(%Ash.Range{}), do: true
  defp period?({:period, _instant}), do: true
  defp period?(_as_of), do: false
end
