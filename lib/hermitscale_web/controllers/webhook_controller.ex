defmodule HermitscaleWeb.WebhookController do
  @moduledoc """
  Inbound HTTP entry point for webhook triggers.

  The controller stays thin: it resolves the hook token to a trigger, builds
  the request struct, and lets the trigger module's `handle_request/2` decide
  fire / reply / ignore. Missing and non-enabled tokens both 404 so the
  endpoint does not confirm which tokens exist.
  """

  use HermitscaleWeb, :controller

  alias Hermitscale.Triggers
  alias Hermitscale.Triggers.Dispatcher
  alias Hermitscale.Workflows
  alias HermitscaleWeb.CacheBodyReader

  @await_default_ms 30_000

  def inbound(conn, %{"token" => token} = path_params) do
    with %Triggers.Trigger{status: :enabled} = trigger <- Triggers.get_webhook_trigger(token) do
      module = Triggers.catalog_module!(trigger)
      params = Triggers.cast_params!(trigger)
      request = build_request(conn, path_params)

      case module.handle_request(request, params) do
        {:fire, payload} ->
          fire(conn, trigger, params, payload, [])

        {:fire, payload, fire_opts} ->
          fire(conn, trigger, params, payload, fire_opts)

        {:reply, status, body} ->
          conn |> put_status(status) |> json(body)

        {:ignore, reason} ->
          conn |> put_status(:accepted) |> json(%{"status" => "ignored", "reason" => reason})

        {:error, :unauthorized} ->
          conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})
      end
    else
      _missing_or_not_enabled ->
        conn |> put_status(:not_found) |> json(%{"error" => "not_found"})
    end
  end

  defp fire(conn, trigger, params, payload, fire_opts) do
    case Dispatcher.fire(trigger, payload, Keyword.take(fire_opts, [:idempotency_key])) do
      {:ok, :deduped} ->
        conn |> put_status(:accepted) |> json(%{"status" => "duplicate"})

      {:ok, run} ->
        respond(conn, params[:respond], run)

      {:error, :rejected} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{"error" => "concurrency_limit_reached"})

      {:error, :disabled} ->
        conn |> put_status(:not_found) |> json(%{"error" => "not_found"})

      {:error, {:start_run, _reason}} ->
        conn |> put_status(:internal_server_error) |> json(%{"error" => "dispatch_failed"})
    end
  end

  defp respond(conn, "when_finished", run) do
    :ok = Workflows.subscribe_run_for_system(run.id)

    # Re-read after subscribing: a fast run may have completed in between, in
    # which case no broadcast is coming.
    run = Workflows.get_run_for_system!(run.id)

    if run.status == :complete do
      completed(conn, run)
    else
      receive do
        {:run_complete, run_id} -> completed(conn, Workflows.get_run_for_system!(run_id))
      after
        await_timeout_ms() -> accepted(conn, run)
      end
    end
  end

  defp respond(conn, _immediately, run), do: accepted(conn, run)

  defp accepted(conn, run) do
    conn |> put_status(:accepted) |> json(%{"status" => "accepted", "run_id" => run.id})
  end

  defp completed(conn, run) do
    json(conn, %{"status" => "complete", "run_id" => run.id, "output" => run.output})
  end

  defp build_request(conn, path_params) do
    conn = Plug.Conn.fetch_query_params(conn)

    %{
      method: conn.method,
      path: Map.get(path_params, "rest", []),
      headers: Map.new(conn.req_headers, fn {name, value} -> {String.downcase(name), value} end),
      query: conn.query_params,
      body: conn.body_params,
      raw_body: CacheBodyReader.raw_body(conn)
    }
  end

  defp await_timeout_ms do
    :hermitscale
    |> Application.get_env(Hermitscale.Triggers, [])
    |> Keyword.get(:webhook_await_timeout_ms, @await_default_ms)
  end
end
