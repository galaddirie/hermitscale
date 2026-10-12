defmodule Hermitscale.Triggers.Mode.Polling do
  @moduledoc """
  Contract for polling-mode triggers.

  A polling trigger owns no process either — it supplies pure functions the
  generic `Hermitscale.Triggers.Runtime.Poller` drives on an interval. The
  cursor is opaque to the runtime: it is whatever JSON-serializable map the
  trigger needs to compute "what is new since last poll", persisted after each
  successful poll so a restarted poller resumes where it left off.

  Events fire at-least-once (a crash between fire and cursor persistence can
  replay a poll); the dispatcher's idempotency key absorbs replays, so include
  a stable `:key` per event whenever the source offers one.

  When the trigger declares `requires: [credentials: ...]`, the runtime
  validates the selected organization account for every `init_cursor/2` and
  `poll/3` call and passes a non-secret reference under `ctx.credentials`.
  Provider clients vend fresh credentials immediately before each request.
  """

  @type ctx :: %{
          required(:trigger_id) => String.t(),
          required(:graph_id) => String.t(),
          optional(:credentials) => map() | nil
        }

  @type event :: %{
          required(:payload) => map(),
          optional(:key) => String.t()
        }

  @type cursor :: map()

  @callback init_cursor(params :: map(), ctx()) :: {:ok, cursor()} | {:error, term()}
  @callback poll(params :: map(), cursor(), ctx()) ::
              {:ok, [event()], cursor()} | {:error, term()}
end
