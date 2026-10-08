# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Temporal.Daily do
  @moduledoc """
  A temporal resource whose period is carved into Sydney days.
  """
  use Ash.Resource,
    domain: Ash.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  temporal do
    strategy :context
    attribute :valid_at
  end

  actions do
    defaults [:read, :destroy, create: [:id, :name], update: [:name]]
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true

    attribute :valid_at, Ash.Type.Range,
      allow_nil?: false,
      constraints: [
        inner_type: :utc_datetime,
        lower: [inclusive?: true],
        upper: [inclusive?: false],
        resolution: Duration.new!(day: 1),
        anchor: DateTime.new!(~D[2025-07-01], ~T[00:00:00], "Australia/Sydney")
      ]
  end
end
