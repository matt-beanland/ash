# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Filter.DataLayerHelpersTest do
  @moduledoc """
  Characterisation tests for the filter helpers every data layer builds on.

  `Ash.Filter.list_refs/1`, `Ash.Filter.map/2`, `Ash.Filter.hydrate_refs/2` and
  `Ash.Resource.Info.selected_by_default_attribute_names/1` are relied upon by
  `ash_sql`, `ash_postgres` and third-party data layers, and nothing here
  exercised them directly — so a change to any one of them broke those layers
  after release rather than failing a test in this repo.

  These describe what the functions do today. They do not argue that the
  behaviour is right; if any of it is wrong, the test should change with it.
  """
  use ExUnit.Case, async: true

  alias Ash.Filter
  alias Ash.Test.Domain, as: Domain

  require Ash.Expr
  require Ash.Query

  defmodule Author do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :secret, :string, public?: true, select_by_default?: false
    end

    relationships do
      has_many :posts, Ash.Test.Filter.DataLayerHelpersTest.Post,
        destination_attribute: :author_id,
        public?: true
    end
  end

  defmodule Post do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true
      attribute :points, :integer, public?: true
    end

    relationships do
      belongs_to :author, Author, public?: true
    end
  end

  defmacrop filter(expr) do
    quote do
      Post |> Ash.Query.filter(unquote(expr)) |> Map.fetch!(:filter)
    end
  end

  describe "Ash.Filter.list_refs/1" do
    test "returns a Ref per attribute the expression names" do
      refs = Filter.list_refs(filter(title == "a" and points > 1))

      assert [:points, :title] == refs |> Enum.map(& &1.attribute.name) |> Enum.sort()
      assert Enum.all?(refs, &match?(%Ash.Query.Ref{}, &1))
    end

    test "an attribute named twice is listed once" do
      refs = Filter.list_refs(filter(title == "a" or title == "b"))

      assert [:title] == Enum.map(refs, & &1.attribute.name)
    end

    test "a ref through a relationship carries its path" do
      refs = Filter.list_refs(filter(author.name == "a"))

      assert [%Ash.Query.Ref{relationship_path: [:author]}] = refs
      assert [:name] == Enum.map(refs, & &1.attribute.name)
    end

    test "an expression naming nothing lists nothing" do
      assert [] == Filter.list_refs(nil)
      assert [] == Filter.list_refs([])
    end
  end

  describe "Ash.Filter.map/2" do
    test "a filter with no expression comes back untouched" do
      empty = %Filter{resource: Post, expression: nil}

      assert ^empty = Filter.map(empty, fn _ -> :never_called end)
    end

    test "the function is applied to each node of a filter's expression" do
      seen =
        filter(title == "a")
        |> Filter.map(fn node ->
          send(self(), {:node, node})
          node
        end)

      assert %Filter{} = seen
      assert_received {:node, _}
    end

    test "it maps a bare expression as well as a filter" do
      assert :replaced = Filter.map(Ash.Expr.expr(title == "a"), fn _ -> :replaced end)
    end

    test "returning {:halt, expr} stops the descent and yields that expression" do
      assert :stopped ==
               Filter.map(Ash.Expr.expr(title == "a" and points > 1), fn _ ->
                 {:halt, :stopped}
               end)
    end
  end

  describe "Ash.Filter.hydrate_refs/2" do
    test "resolves an expression's refs against the resource in the context" do
      assert {:ok, hydrated} =
               Filter.hydrate_refs(Ash.Expr.expr(title == "a"), %{resource: Post, public?: false})

      assert [%Ash.Query.Ref{resource: Post, attribute: %{name: :title}}] =
               Filter.list_refs(hydrated)
    end

    test "a ref reached through a relationship keeps that path" do
      assert {:ok, hydrated} =
               Filter.hydrate_refs(Ash.Expr.expr(author.name == "a"), %{
                 resource: Post,
                 public?: false
               })

      assert [%Ash.Query.Ref{relationship_path: [:author]}] = Filter.list_refs(hydrated)
    end

    test "a ref the resource does not have is an error rather than a raise" do
      assert {:error, _} =
               Filter.hydrate_refs(Ash.Expr.expr(nope == "a"), %{resource: Post, public?: false})
    end
  end

  describe "Ash.Resource.Info.selected_by_default_attribute_names/1" do
    test "is a MapSet of the attributes a read selects without being asked" do
      names = Ash.Resource.Info.selected_by_default_attribute_names(Author)

      assert %MapSet{} = names
      assert MapSet.member?(names, :name)
      assert MapSet.member?(names, :id)
    end

    test "an attribute declaring select_by_default?: false is absent" do
      names = Ash.Resource.Info.selected_by_default_attribute_names(Author)

      refute MapSet.member?(names, :secret)
    end
  end
end
