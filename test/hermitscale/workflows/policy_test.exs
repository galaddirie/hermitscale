defmodule Hermitscale.Workflows.PolicyTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.Policy

  describe "known_keys/0" do
    test "exposes only retry, timeout, deadline, and failure behavior policy keys" do
      assert MapSet.new(Policy.known_keys()) ==
               MapSet.new([
                 "backoff",
                 "on_failure",
                 "max_retries",
                 "base_delay_ms",
                 "max_delay_ms",
                 "timeout_ms",
                 "deadline_ms"
               ])
    end
  end

  describe "normalize/1" do
    test "normalizes supported enum values" do
      assert Policy.normalize(%{"backoff" => "linear", "on_failure" => "halt"}) == %{
               backoff: :linear,
               on_failure: :halt
             }
    end

    test "rejects removed scheduler policy fields" do
      assert_raise KeyError, ~r/"execution_mode"/, fn ->
        Policy.normalize(%{"execution_mode" => "sync"})
      end

      assert_raise KeyError, ~r/"priority"/, fn ->
        Policy.normalize(%{"priority" => "normal"})
      end
    end
  end
end
