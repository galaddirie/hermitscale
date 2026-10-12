defmodule Hermitscale.Workflows.EngineContextTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Integrations.ExecutionContext
  alias Hermitscale.Integrations.CredentialRef
  alias Hermitscale.Workflows.Engine.{Metadata, Node}
  alias Hermitscale.Workflows.Expr
  alias Hermitscale.Workflows.Nodes.ContextProbe.V1, as: Probe
  alias Hermitscale.Workflows.Nodes.ContextReduceProbe.V1, as: ReduceProbe
  alias Hermitscale.Workflows.Nodes.FailureContextProbe.V1, as: FailureProbe
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Invokable, PolicyDriver, SchedulerPolicy}

  describe "catalog callback context" do
    test "expressions and callbacks see the same original item and ancestry" do
      input = Fact.new(value: 20)
      metadata = Metadata.initialize(input)

      frame = %{map: "items", batch: input.hash, item: input.hash, index: 2, size: 4, value: 10}
      state = %{Metadata.state(metadata) | frames: [frame]}
      input = %{input | meta: Metadata.put_state(metadata, state)}

      params = %{
        value: Expr.compile!("{{ $item }}:{{ $itemIndex }}:{{ $json }}:{{ $ancestry[0].map }}")
      }

      node = Node.new(Probe, params, %{name: "probe", parents: []})

      workflow =
        Workflow.new()
        |> Workflow.add(node)
        |> Workflow.put_run_context(%{"probe" => %{observer: self()}})

      {:ok, runnable} = Invokable.prepare(node, workflow, input)
      executed = Invokable.execute(node, runnable)

      assert executed.status == :completed
      assert executed.result.value == "10:2:20:items"
      assert_receive {:engine_context, context}
      assert context.item == 10
      assert context.json == 20
      assert context.item_index == 2
      assert context.ancestry == [frame]
      assert context.activation_id == runnable.activation_id
      assert context.input_id == input.hash

      assert Metadata.state(executed.result.meta).history["probe"]["occurrence"] ==
               executed.result.hash

      refute :erlang.term_to_binary(executed.result.meta) =~ :erlang.term_to_binary(self())
      refute Metadata.runtime_resources?(executed.result.meta)
    end

    test "failed attempts retry with stable item identity and new attempt identity" do
      node =
        Node.new(Probe, %{value: nil, fail_until: 1}, %{name: "probe", parents: []})

      workflow =
        Workflow.new()
        |> Workflow.add(node)
        |> Workflow.put_run_context(%{"probe" => %{observer: self()}})

      input = Fact.new(value: "same")
      {:ok, runnable} = Invokable.prepare(node, workflow, input)
      policy = SchedulerPolicy.new(max_retries: 1, backoff: :none)
      result = PolicyDriver.execute(runnable, policy)

      assert_receive {:engine_context, original}
      assert_receive {:engine_context, retried}
      assert original.activation_id == retried.activation_id
      refute original.attempt_id == retried.attempt_id
      assert retried.attempt_number == 1
      assert result.status == :completed
      assert result.result.value == "same"
      assert Metadata.state(result.result.meta).root == input.hash
      assert original.input_id == retried.input_id
      assert result.error == nil
    end

    test "reducers use fresh runtime and the original context of each ordered item" do
      node =
        Node.new(
          ReduceProbe,
          %{
            initial: 0,
            value: Expr.compile!("{{ $acc | plus: $json | plus: $vars.offset }}"),
            metadata: %{audit: "accepted"}
          },
          %{name: "sum", parents: []}
        )

      input = Fact.new(value: [2, 3])
      metadata = Metadata.initialize(input)

      entries =
        Enum.with_index([2, 3], fn value, index ->
          item = Fact.new(value: value, ancestry: {node.hash, input.hash})

          frame = %{
            map: "items",
            batch: input.hash,
            item: item.hash,
            index: index,
            size: 2,
            value: value
          }

          state = %{Metadata.state(metadata) | frames: [frame]}
          %{value: value, metadata: Metadata.put_state(metadata, state), id: item.hash}
        end)

      input = %{
        input
        | meta:
            Metadata.put_state(metadata, Map.put(Metadata.state(metadata), :collected, entries))
      }

      for {offset, expected} <- [{10, 25}, {100, 205}] do
        workflow =
          Workflow.new()
          |> Workflow.add(node)
          |> Workflow.put_run_context(%{
            "sum" => %{observer: self(), _expr: %{vars: %{"offset" => offset}}}
          })

        {:ok, runnable} = Invokable.prepare(node, workflow, input)
        executed = Invokable.execute(node, runnable)

        assert executed.status == :completed
        assert executed.result.value == expected
        assert executed.result.meta.audit == "accepted"
        assert_receive {:reduce_context, first}
        assert_receive {:reduce_context, second}
        assert {first.item, first.item_index} == {2, 0}
        assert {second.item, second.item_index} == {3, 1}
        assert first.runtime._expr.vars["offset"] == offset
        assert second.runtime._expr.vars["offset"] == offset
      end
    end

    test "empty markers bypass work while remaining correlated" do
      node = Node.new(Probe, %{value: nil}, %{name: "probe", parents: []})
      input = Fact.new(value: nil)
      metadata = Metadata.initialize(input)

      input = %{
        input
        | meta: Metadata.put_state(metadata, %{Metadata.state(metadata) | status: :empty})
      }

      {:ok, runnable} = Invokable.prepare(node, Workflow.new(), input)
      result = Invokable.execute(node, runnable)

      assert result.status == :completed
      assert Metadata.state(result.result.meta).status == :empty
      refute_receive {:engine_context, _}
    end

    test "reducers reject callback metadata that replaces correlation or carries authority" do
      source = Fact.new(value: 1)
      metadata = Metadata.initialize(source)
      entries = [%{value: 1, metadata: metadata, id: source.hash}]

      input = %{
        source
        | meta:
            Metadata.put_state(metadata, Map.put(Metadata.state(metadata), :collected, entries))
      }

      for custom <- [%{hermitscale: %{}}, %{application: %{credentials: "secret"}}] do
        node =
          Node.new(ReduceProbe, %{initial: 0, value: 1, metadata: custom}, %{
            name: "sum",
            parents: []
          })

        workflow =
          Workflow.new()
          |> Workflow.add(node)
          |> Workflow.put_run_context(%{"sum" => %{observer: self()}})

        {:ok, runnable} = Invokable.prepare(node, workflow, input)
        result = Invokable.execute(node, runnable)

        assert result.status == :failed
        assert %ArgumentError{} = result.error
        assert result.result == nil
      end
    end
  end

  describe "durable metadata" do
    test "rejects authority and resources but accepts business payload keys" do
      input = Fact.new(value: %{"user_id" => "customer", "credentials" => "a data field"})
      metadata = Metadata.initialize(input)

      assert Metadata.validate!(metadata) == metadata

      for value <- [
            self(),
            make_ref(),
            fn -> :ok end,
            %ExecutionContext{organization_id: "org", actor_user_id: "user"}
          ] do
        assert_raise ArgumentError, fn ->
          Metadata.put_state(metadata, Map.put(Metadata.state(metadata), :extra, value))
        end
      end

      assert_raise ArgumentError, fn ->
        Metadata.put_state(metadata, Map.put(Metadata.state(metadata), :credentials, "secret"))
      end

      assert_raise ArgumentError, fn ->
        metadata |> Map.put(:application, %{credentials: "secret"}) |> Metadata.validate!()
      end

      assert Metadata.record(metadata, "business", input.value, input.hash).hermitscale.history[
               "business"
             ]["json"] == input.value
    end

    test "merging histories keeps equal values from distinct occurrences" do
      first = Fact.new(value: 1)
      second = Fact.new(value: 1, ancestry: {first.hash, first.hash})
      a = Metadata.record(Metadata.initialize(first), "branch", 7, first.hash)
      b = Metadata.record(Metadata.initialize(first), "branch", 7, second.hash)

      merged = Metadata.merge([a, b, a]) |> Metadata.state()
      assert length(merged.history["branch"]) == 2
      assert Enum.all?(merged.history["branch"], &(&1["json"] == 7))
      assert Enum.map(merged.history["branch"], & &1["occurrence"]) == [first.hash, second.hash]
    end

    test "malformed coordinates fail before expression context construction" do
      input = Fact.new(value: 1)
      metadata = Metadata.initialize(input)
      frame = %{map: "items", batch: input.hash, item: input.hash, index: 1, size: 1, value: 1}

      assert_raise ArgumentError, fn ->
        Metadata.put_state(metadata, %{Metadata.state(metadata) | frames: [frame]})
      end

      assert_raise ArgumentError, fn ->
        Metadata.put_state(metadata, %{
          Metadata.state(metadata)
          | history: %{"node" => %{"json" => 1, "occurrence" => input.hash}}
        })
      end

      assert_raise ArgumentError, fn ->
        Metadata.put_state(metadata, %{
          Metadata.state(metadata)
          | root: %{input.hash | digest: "invalid"}
        })
      end
    end

    test "exhausted failures become scoped durable skips only with the configured fallback" do
      node =
        Node.new(Probe, %{value: nil, fail_until: 5}, %{name: "probe", parents: []})

      workflow =
        Workflow.new()
        |> Workflow.add(node)
        |> Workflow.put_run_context(%{"probe" => %{observer: self()}})

      input = Fact.new(value: "item")
      {:ok, runnable} = Invokable.prepare(node, workflow, input)

      failed = PolicyDriver.execute(runnable, SchedulerPolicy.new(max_retries: 0))
      assert failed.status == :failed
      assert failed.error == :temporary
      assert failed.result == nil

      skipped =
        PolicyDriver.execute(
          runnable,
          SchedulerPolicy.new(max_retries: 1, backoff: :none, fallback: &Node.skip_failure/2)
        )

      assert skipped.status == :completed
      assert Metadata.state(skipped.result.meta).status == :skipped
      assert Metadata.state(skipped.result.meta).root == input.hash
      assert Metadata.state(skipped.result.meta).failed_attempt.attempt_number == 1

      assert Metadata.state(skipped.result.meta).failed_attempt.attempt_id ==
               Runic.Identity.derive(:attempt, [runnable.activation_id, 1])

      assert Metadata.state(skipped.result.meta).reason == "retries exhausted"
      assert skipped.error == nil
    end
  end

  describe "durable failure events" do
    test "callback resources and captured authority are redacted while safe reasons survive" do
      authority = %ExecutionContext{organization_id: "org_test", actor_user_id: "user_test"}

      credentials = %CredentialRef{
        execution_context: authority,
        provider_id: "test",
        account_id: "account",
        required_scopes: []
      }

      for {mode, expected} <- [
            {"credential_failure", {:node_execution_failed, "probe", CredentialRef}},
            {"context_match", {:node_execution_failed, "probe", MatchError}},
            {"safe_failure", {:rate_limited, 60}},
            {"safe_exception", %ArgumentError{message: "invalid business record"}}
          ] do
        node = Node.new(FailureProbe, %{mode: mode}, %{name: "probe", parents: []})

        workflow =
          Workflow.new()
          |> Workflow.add(node)
          |> Workflow.put_run_context(%{"probe" => %{credentials: credentials, observer: self()}})

        {:ok, runnable} = Invokable.prepare(node, workflow, Fact.new(value: "input"))

        {failed, events} =
          PolicyDriver.execute(runnable, SchedulerPolicy.new(max_retries: 0), emit_events: true)

        assert failed.status == :failed
        assert failed.error == expected
        assert Enum.find(events, &is_struct(&1, Runic.Workflow.RunnableFailed)).error == expected

        bytes = :erlang.term_to_binary(events)
        refute Metadata.runtime_resources?(:erlang.binary_to_term(bytes, [:safe]))
        refute bytes =~ :erlang.term_to_binary(credentials)
        refute bytes =~ :erlang.term_to_binary(authority)
        refute bytes =~ :erlang.term_to_binary(self())
      end
    end

    test "definition identity records callback code and requirements" do
      node = Node.new(Probe, %{value: nil}, %{name: "probe", parents: []})
      definition = Runic.Identity.Projectable.identity_document(node)

      assert definition.code_digest == Probe.module_info(:md5)
      assert definition.requires == Probe.__catalog_node__().requires
      assert node.hash == Runic.Identity.derive(:component_definition, definition)
      changed = %{definition | code_digest: <<0::128>>}
      refute node.hash == Runic.Identity.derive(:component_definition, changed)
    end
  end
end
