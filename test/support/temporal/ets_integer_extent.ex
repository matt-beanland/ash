# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Temporal.EtsIntegerExtent do
  @moduledoc """
  A temporal resource whose extent is an integer range rather than a period.

  Temporal requires its attribute to be an `Ash.Type.Range` with inclusive-exclusive
  bounds, and says nothing about the inner type. Keying, non-overlap and as-of
  narrowing are order-theoretic, so they hold for any totally ordered inner type;
  only resolving "now" for a write that did not say when needs a clock.
  """
  use Ash.Resource,
    domain: Ash.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  temporal do
    strategy :context
    attribute :valid_over
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:id, :name]
    end

    update :update do
      accept [:name]
    end
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true

    attribute :valid_over, Ash.Type.Range,
      allow_nil?: false,
      constraints: [inner_type: :integer, bounds: :inclusive_exclusive]
  end
end
