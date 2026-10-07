# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Temporal.Polled do
  @moduledoc """
  A temporal resource whose period is carved into five-minute periods.
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
      generated?: true,
      constraints: [
        inner_type: :datetime,
        lower: [inclusive?: true],
        upper: [inclusive?: false],
        resolution: Duration.new!(minute: 5)
      ]
  end
end
