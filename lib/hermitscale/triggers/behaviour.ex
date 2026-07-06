defmodule Hermitscale.Triggers.Behaviour do
  @moduledoc """
  Behaviour implemented by code-defined trigger catalog nodes.

  Triggers are declared like workflow catalog nodes — a static spec plus pure
  callbacks — and are discovered through the same `Workflows.Catalog`. They
  compile as `kind: :trigger` graph roots: the generated `build/2` produces an
  entry step that unwraps the dispatcher's firing envelope so downstream nodes
  see the trigger payload as `$json`.

  What a trigger must implement beyond the spec depends on its `mode`; the
  matching `Hermitscale.Triggers.Mode.*` behaviour is attached automatically:

    * `:manual` — nothing; fired directly through the dispatcher.
    * `:webhook` — `handle_request/2`, invoked on the inbound HTTP process.
    * `:schedule` — optional `build_payload/2`; the scheduler owns the clock.
    * `:polling` — `init_cursor/2` and `poll/3`, driven by a supervised poller.
    * `:stream` — `init_stream/2` and `handle_event/2`, hosted in a supervised
      stream-source process.
  """

  alias Hermitscale.Triggers.Mode

  @type mode :: :manual | :webhook | :schedule | :polling | :stream

  @callback spec() :: map()
  @callback build(params :: map(), ctx :: map()) :: term()
  @callback validate_params(params :: map()) :: :ok | {:error, String.t()}

  @optional_callbacks validate_params: 1

  @modes ~w(manual webhook schedule polling stream)a

  @mode_behaviours %{
    webhook: Mode.Webhook,
    schedule: Mode.Schedule,
    polling: Mode.Polling,
    stream: Mode.Stream
  }

  defmacro __using__(opts) do
    {opts, _binding} = Code.eval_quoted(opts, [], __CALLER__)
    spec = __compile_spec__!(opts, __CALLER__.module)

    quote do
      require Runic

      @behaviour Hermitscale.Triggers.Behaviour
      unquote(mode_behaviour_ast(spec.mode))
      @__trigger_spec__ unquote(Macro.escape(spec))

      @impl Hermitscale.Triggers.Behaviour
      def spec, do: @__trigger_spec__

      def __catalog_node__, do: @__trigger_spec__

      # The entry step: unwrap the firing envelope into the bare payload so a
      # workflow behaves identically whether dispatched by a trigger or run
      # directly with a plain input.
      @impl Hermitscale.Triggers.Behaviour
      def build(_params, %{name: name}) do
        Runic.step(
          fn input ->
            case input do
              %{"trigger" => %{}, "data" => data} -> data
              other -> other
            end
          end,
          name: name
        )
      end

      unquote(mode_defaults_ast(spec.mode))

      defoverridable build: 2
    end
  end

  @doc false
  def __compile_spec__!(opts, module) do
    assert!(Keyword.keyword?(opts), module, "options must be a keyword list")

    id = require_opt!(opts, :id, module)
    version = require_opt!(opts, :version, module)
    mode = require_opt!(opts, :mode, module)

    # Every trigger accepts the shared admission param the dispatcher reads.
    params =
      opts
      |> Keyword.get(:params, [])
      |> Keyword.put_new(:max_concurrent_runs, type: :pos_integer)

    requires = Keyword.get(opts, :requires, [])
    deprecated = Keyword.get(opts, :deprecated, false)

    assert!(is_binary(id), module, "id must be a string")
    assert!(is_integer(version) and version > 0, module, "version must be a positive integer")
    assert!(mode in @modes, module, "invalid mode #{inspect(mode)}")
    assert!(Keyword.keyword?(requires), module, "requires must be a keyword list")
    assert!(is_boolean(deprecated), module, "deprecated must be a boolean")

    %{
      id: id,
      version: version,
      kind: :trigger,
      mode: mode,
      inputs: [],
      outputs: [:main],
      params_schema: NimbleOptions.new!(params).schema,
      expr_fields: [],
      predicate_fields: [],
      requires: requires,
      default_policy: %{},
      deprecated: deprecated
    }
  end

  defp mode_behaviour_ast(mode) do
    case Map.fetch(@mode_behaviours, mode) do
      {:ok, behaviour} -> quote do: @behaviour(unquote(behaviour))
      :error -> nil
    end
  end

  defp mode_defaults_ast(:schedule) do
    quote do
      @impl Hermitscale.Triggers.Mode.Schedule
      def build_payload(_params, scheduled_at) do
        %{"scheduled_at" => DateTime.to_iso8601(scheduled_at)}
      end

      defoverridable build_payload: 2
    end
  end

  defp mode_defaults_ast(_mode), do: nil

  defp require_opt!(opts, key, module) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{inspect(module)} missing required #{inspect(key)} option"
    end
  end

  defp assert!(true, _module, _message), do: :ok

  defp assert!(false, module, message) do
    raise ArgumentError, "#{inspect(module)} #{message}"
  end
end
