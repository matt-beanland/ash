# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Domain.InfoTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Ash.Domain.Info
  alias Ash.Test.Flow.Domain

  defmodule Named do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    execution do
      short_name(:chosen)
    end
  end

  defmodule Unnamed do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false
  end

  describe "short_name/1" do
    test "returns the declared short_name" do
      assert :chosen == Info.short_name(Named)
    end

    test "falls back to the module's default when none is declared" do
      assert :unnamed == Info.short_name(Unnamed)
    end
  end

  describe "trace_name/1" do
    test "defaults to the short_name stringified" do
      assert "chosen" == Info.trace_name(Named)
      assert "unnamed" == Info.trace_name(Unnamed)
    end
  end

  describe "telemetry_event_name/2" do
    test "uses the declared short_name" do
      assert [:ash, :chosen, :read] == Info.telemetry_event_name(Named, :read)
      assert [:ash, :unnamed, :read] == Info.telemetry_event_name(Unnamed, :read)
    end
  end

  describe "extensions/1" do
    test "returns extensions in use by the domain" do
      assert Ash.Domain.Dsl in Info.extensions(Domain)
      refute Ash.DataLayer.Mnesia in Info.extensions(Domain)
      assert Ash.DataLayer.Mnesia in Info.extensions(Domain, include_resource_extensions?: true)
    end
  end
end
