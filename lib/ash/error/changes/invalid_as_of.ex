# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Error.Changes.InvalidAsOf do
  @moduledoc "Used when a write is given an `as_of` that does not make a valid period"

  use Splode.Error, fields: [:resource, :as_of, :reason, reason_vars: []], class: :invalid

  def message(error) do
    "Cannot write #{inspect(error.resource)} as of #{inspect(error.as_of)}: " <>
      interpolate(error.reason, error.reason_vars)
  end

  defp interpolate(reason, vars) do
    Enum.reduce(vars, reason, fn {key, value}, reason ->
      String.replace(reason, "%{#{key}}", to_string(value))
    end)
  end
end
