defmodule Hermitscale.Workflows.ExprTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.Expr

  describe "compile/1 and resolve!/2" do
    test "interpolates json and env namespaces while preserving literal dollar text" do
      envelope = Expr.ensure_envelope(%{"id" => 42})
      context = Expr.build_context(envelope, %{env: %{"API_BASE" => "https://api.example.test"}})

      compiled =
        Expr.compile!("{{ $env.API_BASE }}/items?$top=5&user={{ $json.id }}")

      assert Expr.resolve!(compiled, context) == "https://api.example.test/items?$top=5&user=42"
    end

    test "returns native values for a single expression" do
      context =
        %{"count" => "7"}
        |> Expr.ensure_envelope()
        |> Expr.build_context(%{})

      assert Expr.resolve!(Expr.compile!("{{ $json.count | to_number }}"), context) == 7
    end

    test "push appends one value to a native list" do
      context = %{"acc" => [20, 40], "json" => 60}

      assert Expr.resolve!(Expr.compile!("{{ $acc | push: $json }}"), context) == [20, 40, 60]
    end

    test "reads upstream node output from the envelope" do
      envelope = %{
        "json" => %{"id" => 42},
        "node" => %{
          "fetch_user" => %{
            "json" => %{"body" => %{"email" => "person@example.test"}}
          }
        }
      }

      context = Expr.build_context(envelope, %{})

      assert Expr.resolve!(Expr.compile!("{{ $node[\"fetch_user\"].json.body.email }}"), context) ==
               "person@example.test"
    end

    test "rejects filters outside the allowlist" do
      assert {:error, %Expr.CompileError{} = error} =
               Expr.compile("{{ $json.id | not_allowed }}")

      assert Exception.message(error) =~ "unknown expression filter"
    end
  end

  describe "node_references/1" do
    test "extracts static node dependencies" do
      compiled =
        Expr.compile!(
          "{{ $node[\"fetch_user\"].json.body.id }}/{{ $node[\"fetch_order\"].json.id }}"
        )

      assert Expr.node_references(compiled) == ["fetch_order", "fetch_user"]
    end
  end
end
