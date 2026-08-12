# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Type.NaiveDateTimeTest do
  @moduledoc false
  use ExUnit.Case, async: true

  require Ash.Query

  alias Ash.Test.Domain, as: Domain

  defmodule Post do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      default_accept :*
      defaults [:read, :destroy, create: :*, update: :*]
    end

    attributes do
      uuid_primary_key :id

      attribute :naive_datetime_a, :naive_datetime do
        public?(true)
      end

      attribute :naive_datetime_b, :naive_datetime, allow_nil?: false, public?: true

      attribute :naive_datetime_usec, :naive_datetime do
        constraints precision: :microsecond
        public?(true)
      end
    end
  end

  test "it handles non-empty values" do
    post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        naive_datetime_a: ~N[2022-04-17 08:30:00],
        naive_datetime_b: ~N[2022-04-17 15:45:30]
      })
      |> Ash.create!()

    assert post.naive_datetime_a == ~N[2022-04-17 08:30:00]
    assert post.naive_datetime_b == ~N[2022-04-17 15:45:30]
  end

  test "it truncates to the second by default" do
    post = create_post(%{naive_datetime_a: ~N[2022-04-17 08:30:00.123456]})

    assert post.naive_datetime_a == ~N[2022-04-17 08:30:00]
  end

  test "it keeps microseconds when the precision says to" do
    post = create_post(%{naive_datetime_usec: ~N[2022-04-17 08:30:00.123456]})

    assert post.naive_datetime_usec == ~N[2022-04-17 08:30:00.123456]
  end

  test "it reads microseconds back out of storage" do
    post = create_post(%{naive_datetime_usec: ~N[2022-04-17 08:30:00.123456]})

    assert [%{naive_datetime_usec: ~N[2022-04-17 08:30:00.123456]}] =
             Ash.read!(Ash.Query.filter(Post, id == ^post.id))
  end

  test "it pads a whole second out to microsecond precision" do
    post = create_post(%{naive_datetime_usec: ~N[2022-04-17 08:30:00]})

    assert post.naive_datetime_usec.microsecond == {0, 6}
  end

  defp create_post(attrs) do
    Post
    |> Ash.Changeset.for_create(
      :create,
      Map.put_new(attrs, :naive_datetime_b, ~N[2022-04-17 15:45:30])
    )
    |> Ash.create!()
  end
end
