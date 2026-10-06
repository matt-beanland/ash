# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Temporal.Limited do
  @moduledoc """
  A temporal resource whose period is limited to the financial year 2025-26.
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
        lower: [inclusive?: true, limit: ~U[2025-07-01 00:00:00Z]],
        upper: [inclusive?: false, limit: ~U[2026-07-01 00:00:00Z]]
      ]
  end
end
