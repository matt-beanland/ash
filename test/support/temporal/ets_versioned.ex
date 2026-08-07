# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Temporal.EtsVersioned do
  @moduledoc """
  A temporal resource on the ETS data layer, used to exercise as-of reads.

  Versions are written with `Ash.Seed.seed!/2`, which goes straight to the data
  layer — a transformer refuses to compile a resource whose period attribute is
  accepted as action input, so there is no action that could set it.
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
    defaults [:read, :destroy]

    create :create do
      accept [:id, :name]
    end
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true

    attribute :valid_at, Ash.Type.Range,
      constraints: [inner_type: :datetime],
      public?: true
  end
end
