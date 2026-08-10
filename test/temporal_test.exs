# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.TemporalTest do
  use ExUnit.Case, async: true

  @as_of ~U[2020-06-15 12:00:00.000000Z]

  describe "Ash.Query.as_of/2" do
    test "sets the field and stashes as_of in the shared context so it propagates" do
      query = Ash.Query.as_of(Ash.Test.Temporal.Thing, @as_of)
      assert query.as_of == @as_of
      assert query.context[:shared][:as_of] == @as_of
    end

    test "defaults to nil" do
      assert Ash.Query.new(Ash.Test.Temporal.Thing).as_of == nil
    end

    test "set_context/2 picks up a propagated shared as_of onto the field" do
      # simulates a related query receiving the parent's shared context
      query =
        Ash.Test.Temporal.Thing
        |> Ash.Query.new()
        |> Ash.Query.set_context(%{shared: %{as_of: @as_of}})

      assert query.as_of == @as_of
    end
  end

  describe "Ash.Changeset temporal API" do
    test "as_of/2 sets the field and threads it into the private context" do
      changeset =
        Ash.Test.Temporal.Thing
        |> Ash.Changeset.new()
        |> Ash.Changeset.as_of(@as_of)

      assert changeset.as_of == @as_of
      assert changeset.context[:private][:as_of] == @as_of
    end
  end

  alias Ash.Test.Temporal.Thing

  describe "as_of threaded through builder opts (like tenant)" do
    test "Ash.Query.for_read/4 reads :as_of from opts" do
      query = Ash.Query.for_read(Thing, :read, %{}, as_of: @as_of)
      assert query.as_of == @as_of
      assert query.context[:shared][:as_of] == @as_of
    end

    test "Ash.Changeset.for_create/4 reads :as_of from opts" do
      changeset = Ash.Changeset.for_create(Thing, :create, %{}, as_of: @as_of)
      assert changeset.as_of == @as_of
      assert changeset.context[:private][:as_of] == @as_of
    end

    test "Ash.Changeset.for_update/4 reads :as_of from opts" do
      thing = Ash.create!(Thing, %{})
      changeset = Ash.Changeset.for_update(thing, :update, %{}, as_of: @as_of)
      assert changeset.as_of == @as_of
    end

    test "Ash.ActionInput.for_action/4 reads :as_of from opts" do
      input = Ash.ActionInput.for_action(Thing, :reveal_as_of, %{}, as_of: @as_of)
      assert input.as_of == @as_of
      assert input.context[:private][:as_of] == @as_of
    end

    test ":now is accepted and carried symbolically" do
      query = Ash.Query.for_read(Thing, :read, %{}, as_of: :now)
      assert query.as_of == :now
    end

    test "absent as_of leaves the subject unset (no as_of context key)" do
      query = Ash.Query.for_read(Thing, :read, %{})
      assert query.as_of == nil
      refute Map.has_key?(query.context, :as_of)
    end
  end

  describe "as_of threaded through Ash.* opts (like tenant)" do
    test "Ash.read/2 threads :as_of from opts onto the query" do
      Ash.create!(Thing, %{name: "a"})
      assert {:ok, _} = Ash.read(Thing, action: :capture_as_of, as_of: @as_of)
      assert_received {:captured_as_of, @as_of}
    end

    test "Ash.get/3 threads :as_of from opts onto the query" do
      thing = Ash.create!(Thing, %{name: "g"})
      assert {:ok, _} = Ash.get(Thing, thing.id, action: :capture_as_of, as_of: @as_of)
      assert_received {:captured_as_of, @as_of}
    end

    test "Ash.run_action/2 threads :as_of into the generic action context" do
      assert {:ok, @as_of} =
               Thing
               |> Ash.ActionInput.for_action(:reveal_as_of, %{})
               |> Ash.run_action(as_of: @as_of)
    end

    test "Ash.run_action/1 sees as_of set on the input itself" do
      input = Ash.ActionInput.for_action(Thing, :reveal_as_of, %{}, as_of: @as_of)
      assert {:ok, @as_of} = Ash.run_action(input)
    end
  end

  describe "as_of threaded through code interfaces (like tenant)" do
    test "generic action interface forwards :as_of into the action context" do
      assert {:ok, @as_of} = Thing.reveal_as_of(as_of: @as_of)
    end

    test "read interface forwards :as_of onto the query" do
      Ash.create!(Thing, %{name: "b"})
      assert {:ok, _} = Thing.capture_as_of(as_of: @as_of)
      assert_received {:captured_as_of, @as_of}
    end
  end

  describe "as_of anchors now() in authorization (policies)" do
    alias Ash.Test.Temporal.Gated

    @t_before ~U[2026-01-15 00:00:00.000000Z]
    @t_after ~U[2026-05-01 00:00:00.000000Z]

    setup do
      Gated |> Ash.Changeset.for_create(:create, %{name: "x"}) |> Ash.create!(authorize?: false)
      :ok
    end

    test "read policy now() is evaluated at as_of, not the wall clock" do
      # now() anchored to @t_before (< cutoff) -> policy passes -> record visible.
      # If early eval resolved now() against the wall clock (2026+), this would be [].
      assert [%{name: "x"}] =
               Gated
               |> Ash.Query.for_read(:read, %{}, actor: %{id: 1}, as_of: @t_before)
               |> Ash.read!(authorize?: true)

      # now() anchored to @t_after (>= cutoff) -> policy filters everything out.
      assert [] =
               Gated
               |> Ash.Query.for_read(:read, %{}, actor: %{id: 1}, as_of: @t_after)
               |> Ash.read!(authorize?: true)
    end

    test "Ash.can threads as_of onto the subject it builds from the action" do
      # can builds the read query from {resource, action}; `as_of` from opts must land on it
      # (Part A). `alter_source?` hands back that built query so we can inspect it directly.
      assert {:ok, _, %Ash.Query{as_of: @t_before}} =
               Ash.can({Gated, :read}, %{id: 1}, as_of: @t_before, alter_source?: true)

      assert {:ok, _, %Ash.Query{as_of: @t_after}} =
               Ash.can({Gated, :read}, %{id: 1}, as_of: @t_after, alter_source?: true)
    end

    test "raises when the actor was fetched as of a different instant than the authorization" do
      actor = %{id: 1, __metadata__: %{as_of: @t_after}}

      assert_raise ArgumentError, ~r/Mismatched `as_of`/, fn ->
        Ash.can?({Gated, :read}, actor, as_of: @t_before)
      end
    end

    test "no raise when the actor's as_of matches the authorization as_of" do
      actor = %{id: 1, __metadata__: %{as_of: @t_before}}
      assert Ash.can?({Gated, :read}, actor, as_of: @t_before)
    end

    test "no raise when the actor carries no as_of stamp (e.g. a non-temporal actor)" do
      assert Ash.can?({Gated, :read}, %{id: 1}, as_of: @t_before)
    end
  end

  describe "fill_template anchors relative time to as_of" do
    # `fill_template` runs on already-hydrated expressions, so it matches the
    # `%Function.Now/Ago/FromNow{}` structs (not the raw `%Ash.Query.Call{}` that `expr/1`
    # produces). Construct the hydrated structs directly to exercise the anchoring.
    alias Ash.Query.Function.{Ago, FromNow, Now, Today}

    @anchor ~U[2026-06-15 12:00:00.000000Z]

    defp anchored(template),
      do: Ash.Expr.fill_template(template, context: %{shared: %{as_of: @anchor}})

    test "now() resolves to as_of" do
      assert anchored(%Now{arguments: []}) == @anchor
    end

    test "ago(n, unit) resolves to as_of shifted into the past" do
      assert anchored(%Ago{arguments: [7, :day]}) == Ago.datetime_add(@anchor, -7, :day)
    end

    test "from_now(n, unit) resolves to as_of shifted into the future" do
      assert anchored(%FromNow{arguments: [7, :day]}) == Ago.datetime_add(@anchor, 7, :day)
    end

    test "today() resolves to the date of as_of" do
      assert anchored(%Today{arguments: []}) == DateTime.to_date(@anchor)
    end

    # `date_add(today(), -7, :day)` is the date-valued counterpart of `ago(7, :day)`.
    # The walker descends into function arguments, so anchoring `today()` anchors
    # every expression built on it.
    test "today() is anchored inside another function's arguments" do
      alias Ash.Query.Function.DateAdd

      assert %DateAdd{arguments: [date, -7, :day]} =
               anchored(%DateAdd{arguments: [%Today{arguments: []}, -7, :day]})

      assert date == DateTime.to_date(@anchor)
    end

    test "ago(duration) resolves to as_of shifted into the past" do
      duration = Duration.new!(day: 7)

      assert anchored(%Ago{arguments: [duration]}) ==
               Ago.datetime_add(@anchor, Duration.negate(duration))
    end

    test "with no as_of in context, relative time is left intact (wall-clock fallback)" do
      no_ctx = [context: %{}]
      assert %Now{arguments: []} = Ash.Expr.fill_template(%Now{arguments: []}, no_ctx)
      assert %Today{arguments: []} = Ash.Expr.fill_template(%Today{arguments: []}, no_ctx)
      assert %Ago{} = Ash.Expr.fill_template(%Ago{arguments: [7, :day]}, no_ctx)
      assert %Ago{} = Ash.Expr.fill_template(%Ago{arguments: [Duration.new!(day: 7)]}, no_ctx)
      assert %FromNow{} = Ash.Expr.fill_template(%FromNow{arguments: [7, :day]}, no_ctx)
    end
  end

  describe "&DateTime.utc_now/0 defaults use as_of" do
    test "a create_timestamp default resolves to the write's as_of, not the wall clock" do
      # Thing has `create_timestamp :inserted_at` (default `&DateTime.utc_now/0`).
      thing =
        Thing
        |> Ash.Changeset.for_create(:create, %{name: "x"}, as_of: @as_of)
        |> Ash.create!()

      assert thing.inserted_at == @as_of
    end

    test "without as_of the default is the wall clock" do
      before = DateTime.utc_now()
      thing = Ash.create!(Thing, %{name: "x"})
      assert DateTime.compare(thing.inserted_at, before) in [:eq, :gt]
    end
  end

  describe "Ets serves as-of reads" do
    alias Ash.Test.Temporal.EtsVersioned

    @early %Ash.Range{
      lower: ~U[2020-01-01 00:00:00Z],
      upper: ~U[2021-01-01 00:00:00Z],
      bounds: :"[)"
    }
    @open %Ash.Range{lower: ~U[2021-01-01 00:00:00Z], upper: nil, bounds: :"[)"}

    setup do
      # Two versions of ONE record: the same primary key, adjacent periods. Both
      # survive because the period is part of the storage key.
      Ash.Seed.seed!(%EtsVersioned{id: 1, name: "early", valid_at: @early})
      Ash.Seed.seed!(%EtsVersioned{id: 1, name: "open", valid_at: @open})
      :ok
    end

    test "an instant selects the records whose period holds it" do
      assert [%{name: "early"}] =
               EtsVersioned |> Ash.Query.as_of(~U[2020-06-01 00:00:00Z]) |> Ash.read!()

      assert [%{name: "open"}] =
               EtsVersioned |> Ash.Query.as_of(~U[2026-06-01 00:00:00Z]) |> Ash.read!()
    end

    # The half-open rule at the seam: the instant the two periods share belongs
    # to the later one only.
    test "a shared boundary belongs to the later period" do
      assert [%{name: "open"}] =
               EtsVersioned |> Ash.Query.as_of(~U[2021-01-01 00:00:00Z]) |> Ash.read!()
    end

    test "an instant before every period returns nothing" do
      assert [] = EtsVersioned |> Ash.Query.as_of(~U[2019-01-01 00:00:00Z]) |> Ash.read!()
    end

    test "a read with no as_of is anchored to now, so it sees current state" do
      assert [%{name: "open"}] = EtsVersioned |> Ash.read!()
    end
  end

  describe "Ets keys a temporal record by its period" do
    alias Ash.Test.Temporal.EtsVersioned

    test "the period joins the key of a temporal resource, and only there" do
      record = %EtsVersioned{id: 1, name: "x", valid_at: @open}

      assert Ash.DataLayer.Ets.pkey_map(EtsVersioned, record) == %{id: 1, valid_at: @open}
      assert Ash.DataLayer.Ets.pkey_map(Thing, %{id: "abc", name: "y"}) == %{id: "abc"}
    end

    # Keyed on the primary key alone, the second write lands on the first and the
    # earlier version is gone — so the store could only ever hold current state.
    test "two versions of one record are stored side by side" do
      Ash.Seed.seed!(%EtsVersioned{id: 1, name: "early", valid_at: @early})
      Ash.Seed.seed!(%EtsVersioned{id: 1, name: "open", valid_at: @open})

      assert [%{id: 1, name: "early"}] =
               EtsVersioned |> Ash.Query.as_of(~U[2020-06-01 00:00:00Z]) |> Ash.read!()

      assert [%{id: 1, name: "open"}] =
               EtsVersioned |> Ash.Query.as_of(~U[2026-06-01 00:00:00Z]) |> Ash.read!()
    end

    # A version is addressable, which is what makes it a record rather than a
    # projection of one: destroying it takes that period and nothing else.
    test "destroying one version leaves the others" do
      early = Ash.Seed.seed!(%EtsVersioned{id: 1, name: "early", valid_at: @early})
      Ash.Seed.seed!(%EtsVersioned{id: 1, name: "open", valid_at: @open})

      Ash.destroy!(early)

      assert [] = EtsVersioned |> Ash.Query.as_of(~U[2020-06-01 00:00:00Z]) |> Ash.read!()

      assert [%{name: "open"}] =
               EtsVersioned |> Ash.Query.as_of(~U[2026-06-01 00:00:00Z]) |> Ash.read!()
    end
  end

  describe "Ets establishes a period on create" do
    alias Ash.Test.Temporal.EtsVersioned

    # Every test above seeds its periods, which goes straight to the data layer.
    # A record created through an action cannot: a transformer refuses a resource
    # whose period attribute is accepted as action input, so nothing above the data
    # layer is able to set one. Without the layer establishing it, such a record
    # carries no period, and `as_of_matches/3` drops exactly those — so an ordinary
    # create was invisible to every as-of read, including a read with no as_of.
    # The bound is cast through the period's inner type, and `:datetime` is
    # second-resolution — so it is truncated, and can precede the wall clock at the
    # moment of the write by up to a second. Compared at the period's own precision
    # for that reason: a record is valid from the start of the second it was written
    # in, not from the microsecond.
    test "a created record is valid from the write, with no end" do
      before = DateTime.utc_now() |> DateTime.truncate(:second)

      record =
        EtsVersioned
        |> Ash.Changeset.for_create(:create, %{id: 10, name: "made"})
        |> Ash.create!()

      assert %Ash.Range{lower: lower, upper: nil, bounds: :"[)"} = record.valid_at
      assert DateTime.compare(lower, before) in [:gt, :eq]
    end

    test "and is therefore visible to a read, before and after being written" do
      EtsVersioned
      |> Ash.Changeset.for_create(:create, %{id: 11, name: "visible"})
      |> Ash.create!()

      assert [%{name: "visible"}] = EtsVersioned |> Ash.read!()

      assert [%{name: "visible"}] =
               EtsVersioned |> Ash.Query.as_of(DateTime.utc_now()) |> Ash.read!()

      # Its validity starts at the write, so an earlier instant holds nothing.
      assert [] = EtsVersioned |> Ash.Query.as_of(~U[2020-01-01 00:00:00Z]) |> Ash.read!()
    end

    test "an explicit as_of anchors the period rather than the layer's clock" do
      as_of = ~U[2022-03-04 05:06:07Z]

      record =
        EtsVersioned
        |> Ash.Changeset.for_create(:create, %{id: 12, name: "pinned"})
        |> Ash.Changeset.as_of(as_of)
        |> Ash.create!()

      assert %Ash.Range{lower: ^as_of, upper: nil} = record.valid_at
      assert [%{name: "pinned"}] = EtsVersioned |> Ash.Query.as_of(as_of) |> Ash.read!()
    end

    # A bulk create takes its own path through the layer, so it establishes the
    # period separately. It is the same rule: created is valid from the write.
    test "a bulk-created record is established the same way" do
      assert %Ash.BulkResult{records: [record]} =
               Ash.bulk_create!([%{id: 13, name: "bulked"}], EtsVersioned, :create,
                 return_records?: true
               )

      assert %Ash.Range{lower: %DateTime{}, upper: nil, bounds: :"[)"} = record.valid_at
      assert [%{name: "bulked"}] = EtsVersioned |> Ash.read!()
    end
  end

  describe "Ets refuses versions of one record that overlap" do
    alias Ash.Test.Temporal.EtsVersioned

    defp create_at(id, name, as_of) do
      EtsVersioned
      |> Ash.Changeset.for_create(:create, %{id: id, name: name})
      |> Ash.Changeset.as_of(as_of)
      |> Ash.create()
    end

    # Both creates open a period with no end, so the later one holds every instant
    # the earlier one does from its own start onwards. An as-of read there would
    # answer with two records for a resource that has one.
    test "a second open-ended version of one record is refused" do
      assert {:ok, _} = create_at(1, "first", ~U[2020-01-01 00:00:00Z])

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidAttribute{} = error]}} =
               create_at(1, "second", ~U[2021-01-01 00:00:00Z])

      assert error.field == :valid_at
      assert error.message =~ "overlaps the period of an existing version"

      assert [%{name: "first"}] =
               EtsVersioned |> Ash.Query.as_of(~U[2021-06-01 00:00:00Z]) |> Ash.read!()
    end

    test "adjacent versions of one record are accepted, since they share no instant" do
      Ash.Seed.seed!(%EtsVersioned{id: 1, name: "early", valid_at: @early})

      assert {:ok, _} = create_at(1, "later", ~U[2021-01-01 00:00:00Z])

      assert [%{name: "early"}] =
               EtsVersioned |> Ash.Query.as_of(~U[2020-06-01 00:00:00Z]) |> Ash.read!()

      assert [%{name: "later"}] =
               EtsVersioned |> Ash.Query.as_of(~U[2021-06-01 00:00:00Z]) |> Ash.read!()
    end

    test "another record's overlapping period is no concern of this one's" do
      assert {:ok, _} = create_at(1, "one", ~U[2020-01-01 00:00:00Z])
      assert {:ok, _} = create_at(2, "two", ~U[2020-01-01 00:00:00Z])
    end

    test "a bulk create must not overlap what is already stored" do
      Ash.Seed.seed!(%EtsVersioned{id: 1, name: "open", valid_at: @open})

      assert %Ash.BulkResult{status: :error, errors: [error]} =
               Ash.bulk_create([%{id: 1, name: "clash"}], EtsVersioned, :create,
                 return_errors?: true
               )

      assert %Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidAttribute{field: :valid_at}]} =
               error
    end

    # Nothing in the batch is stored until the batch is written, so a batch that
    # clashes with itself has nothing to be compared against unless the records
    # already accepted are carried along.
    test "nor overlap its own earlier records" do
      assert %Ash.BulkResult{status: :error, errors: [error]} =
               Ash.bulk_create(
                 [%{id: 1, name: "first"}, %{id: 1, name: "second"}],
                 EtsVersioned,
                 :create,
                 return_errors?: true
               )

      assert %Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidAttribute{field: :valid_at}]} =
               error
    end
  end

  describe "Ets supersedes a version on update" do
    alias Ash.Test.Temporal.EtsVersioned

    defp update_at(record, name, as_of) do
      record
      |> Ash.Changeset.for_update(:update, %{name: name})
      |> Ash.Changeset.as_of(as_of)
      |> Ash.update!()
    end

    defp names_at(instant) do
      EtsVersioned
      |> Ash.Query.as_of(instant)
      |> Ash.read!()
      |> Enum.map(& &1.name)
    end

    test "the version being updated keeps the values it held, up to the write" do
      record = Ash.Seed.seed!(%EtsVersioned{id: 1, name: "first", valid_at: @open})

      updated = update_at(record, "second", ~U[2023-01-01 00:00:00Z])

      assert %Ash.Range{lower: ~U[2023-01-01 00:00:00Z], upper: nil, bounds: :"[)"} =
               updated.valid_at

      assert ["first"] = names_at(~U[2022-01-01 00:00:00Z])
      assert ["second"] = names_at(~U[2023-06-01 00:00:00Z])
      # The instant of the write belongs to the version it opens, not the one it closes.
      assert ["second"] = names_at(~U[2023-01-01 00:00:00Z])
    end

    # An update splits a version; it does not extend one. Were the new half opened
    # with no end, updating a version that had already been closed would make the
    # record valid forever on the strength of an edit.
    test "the new version ends where the one it split ended" do
      record = Ash.Seed.seed!(%EtsVersioned{id: 1, name: "first", valid_at: @early})

      updated = update_at(record, "second", ~U[2020-06-01 00:00:00Z])

      assert %Ash.Range{
               lower: ~U[2020-06-01 00:00:00Z],
               upper: ~U[2021-01-01 00:00:00Z]
             } = updated.valid_at

      assert ["first"] = names_at(~U[2020-03-01 00:00:00Z])
      assert ["second"] = names_at(~U[2020-09-01 00:00:00Z])
      assert [] = names_at(~U[2021-06-01 00:00:00Z])
    end

    # Splitting at the instant a version began leaves a half that holds no instant.
    # It is dropped rather than stored, and the update reads as an ordinary
    # overwrite — the same thing it would have been before any of this.
    test "an update at the instant the version began overwrites it" do
      record = Ash.Seed.seed!(%EtsVersioned{id: 1, name: "first", valid_at: @open})

      updated = update_at(record, "second", @open.lower)

      assert updated.valid_at == @open
      assert ["second"] = names_at(~U[2021-06-01 00:00:00Z])
    end

    test "with no as_of the split happens on the layer's own clock" do
      record = Ash.Seed.seed!(%EtsVersioned{id: 1, name: "first", valid_at: @open})
      before = DateTime.utc_now() |> DateTime.truncate(:second)

      updated =
        record
        |> Ash.Changeset.for_update(:update, %{name: "second"})
        |> Ash.update!()

      assert %Ash.Range{lower: lower, upper: nil} = updated.valid_at
      assert DateTime.compare(lower, before) in [:gt, :eq]

      assert ["first"] = names_at(~U[2021-06-01 00:00:00Z])
      assert ["second"] = EtsVersioned |> Ash.read!() |> Enum.map(& &1.name)
    end

    # A version cannot be split at an instant it does not hold: the record being
    # updated is not the one that was valid then, which is what this layer already
    # means by stale. Through an action the refusal comes earlier and from core —
    # the atomic upgrade re-reads the record at the write's `as_of` and finds
    # nothing — so these are two tests, and the layer's own guard is the backstop
    # for a caller that reaches it directly.
    test "an update at an instant the version does not hold is refused" do
      record = Ash.Seed.seed!(%EtsVersioned{id: 1, name: "first", valid_at: @early})

      assert_raise Ash.Error.Invalid, ~r/stale record/, fn ->
        update_at(record, "second", ~U[2026-01-01 00:00:00Z])
      end

      assert ["first"] = names_at(~U[2020-06-01 00:00:00Z])
    end

    test "and the layer refuses it on its own account, naming the period" do
      record = Ash.Seed.seed!(%EtsVersioned{id: 1, name: "first", valid_at: @early})

      changeset =
        record
        |> Ash.Changeset.for_update(:update, %{name: "second"})
        |> Ash.Changeset.as_of(~U[2026-01-01 00:00:00Z])

      assert {:error, %Ash.Error.Changes.StaleRecord{field: :valid_at}} =
               Ash.DataLayer.update(EtsVersioned, changeset)

      assert ["first"] = names_at(~U[2020-06-01 00:00:00Z])
    end
  end

  describe "the period attribute" do
    alias Ash.Test.Temporal.EtsVersioned

    test "is declared for you when the resource does not declare it" do
      attribute = Ash.Resource.Info.attribute(EtsVersioned, :valid_at)

      assert attribute.type == Ash.Type.Range
      assert attribute.constraints[:inner_type] == Ash.Type.DateTime
      assert Ash.Range.notation(attribute.constraints[:bounds]) == :"[)"
      refute attribute.allow_nil?

      # Ash's own default for an attribute; declaring the period does not make it
      # part of the public interface.
      refute attribute.public?
    end

    test "the inner type is introspectable, without reaching through the attribute" do
      assert Ash.Resource.Info.temporal_inner_type(EtsVersioned) == Ash.Type.DateTime
      assert Ash.Resource.Info.temporal_period(EtsVersioned).name == :valid_at
      assert Keyword.keyword?(Ash.Resource.Info.temporal_inner_constraints(EtsVersioned))
      assert is_nil(Ash.Resource.Info.temporal_inner_type(Ash.Test.Temporal.Thing))
    end

    test "declaring it yourself is how the inner type and its constraints are chosen" do
      # Temporal reads the attribute rather than restating any of it.
      defmodule DatePeriod do
        use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

        temporal do
          strategy :context
        end

        attributes do
          attribute :id, :integer, primary_key?: true, allow_nil?: false

          attribute :valid_at, Ash.Type.Range,
            allow_nil?: false,
            constraints: [inner_type: :date, bounds: :inclusive_exclusive]
        end

        actions do
          defaults [:read]
        end
      end

      assert Ash.Resource.Info.temporal_inner_type(DatePeriod) == Ash.Type.Date
    end

    test "sub-second detail survives when the attribute asks for it" do
      defmodule MicrosecondPeriod do
        use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

        temporal do
          strategy :context
        end

        attributes do
          attribute :id, :integer, primary_key?: true, allow_nil?: false

          attribute :valid_at, Ash.Type.Range,
            allow_nil?: false,
            constraints: [
              inner_type: :datetime,
              inner_constraints: [precision: :microsecond],
              bounds: :inclusive_exclusive
            ]
        end

        actions do
          defaults [:read]
        end
      end

      instant = ~U[2026-01-01 00:00:00.123456Z]
      constraints = Ash.Resource.Info.attribute(MicrosecondPeriod, :valid_at).constraints

      {:ok, range} =
        Ash.Type.cast_input(Ash.Type.Range, %{lower: instant, upper: nil}, constraints)

      {:ok, range} = Ash.Type.apply_constraints(Ash.Type.Range, range, constraints)

      assert range.lower == instant
    end

    test "a resource may declare every part of the period itself" do
      defmodule FullyDeclared do
        use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

        temporal do
          strategy :context
          attribute :effective_at
        end

        attributes do
          attribute :id, :integer, primary_key?: true, allow_nil?: false

          attribute :effective_at, Ash.Type.Range,
            allow_nil?: false,
            public?: true,
            constraints: [
              inner_type: :datetime,
              inner_constraints: [precision: :microsecond],
              bounds: :inclusive_exclusive
            ]
        end

        actions do
          defaults [:read]
        end
      end

      assert Ash.Resource.Info.temporal_attribute(FullyDeclared) == :effective_at
      assert Ash.Resource.Info.temporal_inner_type(FullyDeclared) == Ash.Type.DateTime

      assert Ash.Resource.Info.temporal_inner_constraints(FullyDeclared)[:precision] ==
               :microsecond

      attribute = Ash.Resource.Info.temporal_period(FullyDeclared)
      assert attribute.name == :effective_at
      assert attribute.public?
    end

    test "a period declared under a name of the resource's choosing is created there" do
      defmodule NamedPeriod do
        use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

        temporal do
          strategy :context
          attribute :effective_at
        end

        attributes do
          attribute :id, :integer, primary_key?: true, allow_nil?: false
        end

        actions do
          defaults [:read]
        end
      end

      assert Ash.Resource.Info.temporal_period(NamedPeriod).name == :effective_at
      assert is_nil(Ash.Resource.Info.attribute(NamedPeriod, :valid_at))
    end

    test "omitting the bounds constraint is refused, not assumed" do
      assert_raise Spark.Error.DslError,
                   ~r/constrain its `bounds` to `:inclusive_exclusive`/,
                   fn ->
                     defmodule UnboundedPeriod do
                       use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

                       temporal do
                         strategy :context
                       end

                       attributes do
                         attribute :id, :integer, primary_key?: true, allow_nil?: false

                         attribute :valid_at, Ash.Type.Range,
                           allow_nil?: false,
                           constraints: [inner_type: :datetime]
                       end

                       actions do
                         defaults [:read]
                       end
                     end
                   end
    end

    test "must be inclusive-exclusive" do
      assert_raise Spark.Error.DslError,
                   ~r/constrain its `bounds` to `:inclusive_exclusive`/,
                   fn ->
                     defmodule ClosedPeriod do
                       use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

                       temporal do
                         strategy :context
                       end

                       attributes do
                         attribute :id, :integer, primary_key?: true, allow_nil?: false

                         attribute :valid_at, Ash.Type.Range,
                           constraints: [inner_type: :datetime, bounds: :inclusive_inclusive]
                       end

                       actions do
                         defaults [:read]
                       end
                     end
                   end
    end

    test "as_of_matches/3 narrows records, so a data layer need not rebuild it" do
      period = %Ash.Range{
        lower: ~U[2020-01-01 00:00:00Z],
        upper: ~U[2021-01-01 00:00:00Z],
        bounds: :"[)"
      }

      records = [%{valid_at: period}]
      narrow = &Ash.Filter.Runtime.as_of_matches(records, EtsVersioned, &1)

      assert [_] = narrow.(~U[2020-06-01 00:00:00Z])
      assert [] = narrow.(~U[2019-06-01 00:00:00Z])

      # Half-open: the lower bound is held, the upper is not, which is what lets
      # the next period start exactly where this one ends.
      assert [_] = narrow.(~U[2020-01-01 00:00:00Z])
      assert [] = narrow.(~U[2021-01-01 00:00:00Z])
    end

    test "as_of_matches/3 drops a record carrying no period" do
      assert [] =
               Ash.Filter.Runtime.as_of_matches(
                 [%{valid_at: nil}],
                 EtsVersioned,
                 ~U[2020-06-01 00:00:00Z]
               )
    end

    test "as_of_matches/3 leaves a non-temporal resource untouched" do
      records = [%{name: "a"}, %{name: "b"}]

      assert ^records =
               Ash.Filter.Runtime.as_of_matches(
                 records,
                 Ash.Test.Temporal.Thing,
                 ~U[2020-06-01 00:00:00Z]
               )
    end

    test "must not be nullable, since a row is valid over some period" do
      assert_raise Spark.Error.DslError, ~r/not to be `allow_nil\? true`/, fn ->
        defmodule NullablePeriod do
          use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

          temporal do
            strategy :context
          end

          attributes do
            attribute :id, :integer, primary_key?: true, allow_nil?: false

            attribute :valid_at, Ash.Type.Range,
              allow_nil?: true,
              constraints: [inner_type: :datetime, bounds: :inclusive_exclusive]
          end

          actions do
            defaults [:read]
          end
        end
      end
    end

    test "must be a range" do
      assert_raise Spark.Error.DslError, ~r/to be an `Ash.Type.Range`/, fn ->
        defmodule NotARangePeriod do
          use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

          temporal do
            strategy :context
          end

          attributes do
            attribute :id, :integer, primary_key?: true, allow_nil?: false
            attribute :valid_at, :datetime
          end

          actions do
            defaults [:read]
          end
        end
      end
    end
  end
end
