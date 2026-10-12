defmodule Hermitscale.Triggers.Mode.Stream do
  @moduledoc """
  Contract for stream-mode triggers (long-lived connections: WebSockets,
  server-sent events, message-queue consumers).

  The generic `Hermitscale.Triggers.Runtime.StreamSource` GenServer owns the
  process lifecycle — registration, restart, reconnect backoff — and delegates
  protocol work to the trigger module. `init_stream/2` establishes the
  connection (any messages the connection delivers arrive as `handle_event/2`
  calls, since the StreamSource process is the one that opened it), and
  `handle_event/2` translates inbound messages into firings.
  """

  @type ctx :: %{
          required(:trigger_id) => String.t(),
          required(:graph_id) => String.t(),
          optional(:credentials) => map() | nil
        }

  @type state :: term()

  @callback init_stream(params :: map(), ctx()) :: {:ok, state()} | {:error, term()}
  @callback handle_event(message :: term(), state()) ::
              {:fire, [payload :: map()], state()}
              | {:noreply, state()}
              | {:reconnect, reason :: term(), state()}
              | {:stop, reason :: term()}
              | {:error, reason :: term()}
  @callback terminate_stream(reason :: term(), state()) :: :ok

  @optional_callbacks terminate_stream: 2
end
