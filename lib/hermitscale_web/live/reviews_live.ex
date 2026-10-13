defmodule HermitscaleWeb.ReviewsLive do
  @moduledoc "Concrete, scoped approval requests and durable human decisions."
  use HermitscaleWeb, :live_view
  alias Hermitscale.{Artifacts, Authorization, Reviews}

  @focus "focus-visible:outline-[3px] focus-visible:outline-offset-2 focus-visible:outline-base-content"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Reviews")
     |> assign(:review, nil)
     |> assign(:artifact, nil)
     |> assign(:patch, nil)
     |> assign(:artifact_unavailable?, false)
     |> assign(:decision_enabled?, false)
     |> assign(:expired?, false)
     |> assign(:decision_message, nil)
     |> assign(:focus_class, @focus)
     |> stream(:reviews, [], dom_id: &"review-#{&1.id}")
     |> stream(:exports, [], dom_id: &export_dom_id/1)}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    case Reviews.list(socket.assigns.current_scope) do
      reviews when is_list(reviews) ->
        {:noreply,
         socket
         |> assign(:review, nil)
         |> assign(:page_title, "Reviews")
         |> stream(:reviews, reviews, reset: true)}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, "Your role does not allow viewing reviews.")
         |> push_navigate(to: ~p"/")}
    end
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    case Reviews.get(socket.assigns.current_scope, id) do
      {:ok, review} ->
        if connected?(socket), do: Reviews.subscribe(socket.assigns.current_scope, review.id)
        {:noreply, load_review(socket, review)}

      {:error, reason} when reason in [:not_found, :forbidden] ->
        {:noreply,
         socket
         |> put_flash(:error, "This review is unavailable.")
         |> push_navigate(to: ~p"/reviews")}
    end
  end

  @impl true
  def handle_event("decide", %{"decision" => "approved"}, socket), do: decide(socket, :approved)
  def handle_event("decide", %{"decision" => "rejected"}, socket), do: decide(socket, :rejected)

  def handle_event("decide", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Choose approve or reject.")}

  def handle_event("refresh", _params, %{assigns: %{review: nil}} = socket) do
    case Reviews.list(socket.assigns.current_scope) do
      reviews when is_list(reviews) ->
        {:noreply, stream(socket, :reviews, reviews, reset: true)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Your role does not allow viewing reviews.")}
    end
  end

  def handle_event("refresh", _params, socket), do: refresh_review(socket)

  @impl true
  def handle_info({:review_updated, id}, %{assigns: %{review: %{id: id}}} = socket),
    do: refresh_review(socket)

  def handle_info({:review_updated, _other_review_id}, socket), do: {:noreply, socket}

  defp refresh_review(socket) do
    case Reviews.get(socket.assigns.current_scope, socket.assigns.review.id) do
      {:ok, review} ->
        {:noreply, load_review(socket, review)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "This review is unavailable.")
         |> push_navigate(to: ~p"/reviews")}
    end
  end

  defp decide(%{assigns: %{review: nil}} = socket, _decision),
    do: {:noreply, put_flash(socket, :error, "Open a review before deciding.")}

  defp decide(%{assigns: %{decision_enabled?: false}} = socket, _decision),
    do: {:noreply, put_flash(socket, :error, "This request cannot be decided from this page.")}

  defp decide(socket, decision) do
    case Reviews.decide(socket.assigns.current_scope, socket.assigns.review.id, decision) do
      {:ok, review} ->
        message =
          case decision do
            :approved -> "Approved. The waiting operation can continue."
            :rejected -> "Rejected. This action has no approval to continue."
          end

        {:noreply, socket |> load_review(review) |> assign(:decision_message, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, decision_error(reason))}
    end
  end

  defp load_review(socket, review) do
    scope = socket.assigns.current_scope
    expired? = DateTime.compare(review.expires_at, DateTime.utc_now(:second)) != :gt
    {artifact, patch, exports, artifact_unavailable?} = evidence(scope, review)
    eligible? = scope.user.id in review.eligible_approver_ids
    can_decide? = Authorization.authorize(scope, "reviews:decide") == :ok

    socket
    |> assign(:review, review)
    |> assign(:page_title, action_label(review.action) <> " review")
    |> assign(:artifact, artifact)
    |> assign(:patch, patch)
    |> assign(:artifact_unavailable?, artifact_unavailable?)
    |> assign(:expired?, expired?)
    |> stream(:exports, exports, reset: true)
    |> assign(
      :decision_enabled?,
      can_decide? and eligible? and not expired? and review.status == :requested and
        not artifact_unavailable? and review.target != %{}
    )
  end

  defp evidence(scope, review) do
    id =
      Map.get(
        review.target,
        "patch_snapshot_artifact_id",
        Map.get(review.target, "patch_artifact_id")
      )

    case id do
      nil ->
        {nil, nil, [], false}

      id ->
        case Artifacts.get(scope, id) do
          {:ok, artifact} ->
            case patch_content(artifact) do
              {:ok, patch, snapshot_exports} ->
                case read_exports(scope, artifact, snapshot_exports) do
                  {:ok, exports} ->
                    {Map.take(artifact, [:id, :kind, :digest, :size_bytes]),
                     patch |> String.slice(0, 131_072) |> :binary.copy(), exports, false}

                  :unavailable ->
                    {nil, nil, [], true}
                end

              :unavailable ->
                {nil, nil, [], true}
            end

          {:error, _reason} ->
            {nil, nil, [], true}
        end
    end
  end

  defp patch_content(%{kind: "patch", content: content}), do: {:ok, content, []}

  defp patch_content(%{kind: "patch_snapshot", content: content}) do
    case Jason.decode(content) do
      {:ok, %{"diff" => diff} = snapshot} when is_binary(diff) ->
        {:ok, diff, Map.get(snapshot, "exports", [])}

      _invalid_evidence ->
        :unavailable
    end
  end

  defp patch_content(_artifact), do: :unavailable

  defp read_exports(scope, snapshot, exports) when is_list(exports) do
    Enum.reduce_while(exports, {:ok, []}, fn
      %{"path" => path, "artifact_id" => id, "digest" => digest}, {:ok, selected}
      when is_binary(path) and is_binary(id) and is_binary(digest) ->
        case Artifacts.get(scope, id) do
          {:ok,
           %{kind: "workspace_file", owner_type: "session", owner_id: owner, digest: ^digest}}
          when owner == snapshot.owner_id ->
            {:cont, {:ok, [%{id: id, path: path, digest: digest} | selected]}}

          _unavailable ->
            {:halt, :unavailable}
        end

      _invalid, _selected ->
        {:halt, :unavailable}
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      :unavailable -> :unavailable
    end
  end

  defp read_exports(_scope, _snapshot, _exports), do: :unavailable

  defp export_dom_id(export),
    do:
      "review-export-" <>
        export.id <> "-" <> (:crypto.hash(:sha256, export.path) |> Base.encode16(case: :lower))

  defp target_entries(target) do
    target
    |> Map.drop(
      ~w(operation_key review_id candidate_digest patch_artifact_id patch_snapshot_artifact_id _connection)
    )
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: Jason.encode!(value, pretty: true)
  defp field_label(key), do: key |> String.replace("_", " ") |> String.capitalize()
  defp action_label("agents.publish_branch"), do: "Publish branch"
  defp action_label("apps.deploy"), do: "Deploy app"
  defp action_label("apps.publish"), do: "Publish app"
  defp action_label("apps.restore_data"), do: "Restore app data"
  defp action_label("support.reply"), do: "Send support reply"
  defp action_label(action), do: action |> String.replace("_", " ") |> String.replace(".", " · ")
  defp status_label(:requested), do: "Waiting for a decision"
  defp status_label(:approved), do: "Approved"
  defp status_label(:rejected), do: "Rejected"

  defp decision_error(:review_expired),
    do: "This review expired. Request a new review for the current action."

  defp decision_error(:ineligible_approver), do: "This request names another reviewer."

  defp decision_error(:review_already_decided),
    do: "A decision has already been recorded. Refresh to see it."

  defp decision_error(reason) when reason in [:forbidden, :execution_actor_ineligible],
    do: "Your current role does not allow this decision."

  defp decision_error(reason) when reason in [:unavailable, :rate_limited],
    do: "The identity service is unavailable. Try the decision again."

  defp decision_error(reason), do: "The decision could not be recorded: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl text-base-content">
        <div class="mb-8 flex flex-wrap items-start justify-between gap-4">
          <div>
            <.link
              :if={@review}
              navigate={~p"/reviews"}
              class={["mb-3 inline-flex items-center gap-2 rounded-lg text-sm", @focus_class]}
            >
              <.icon name="hero-arrow-left" class="size-4" /> All reviews
            </.link>
            <p class="text-sm font-medium">Human approval</p>
            <h1 id="reviews-heading" class="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
              {if @review, do: action_label(@review.action), else: "Reviews"}
            </h1>
            <p class="mt-3 max-w-2xl text-sm leading-6">
              {if @review,
                do: "Inspect the exact action and its evidence before making a decision.",
                else: "Actions waiting for approval, alongside their recorded decisions."}
            </p>
          </div>
          <button
            id="refresh-reviews"
            type="button"
            phx-click="refresh"
            phx-disable-with="Refreshing..."
            class={[
              "inline-flex items-center gap-2 rounded-xl border border-base-content/30 bg-base-100 px-4 py-2.5 text-sm font-medium transition hover:bg-base-200",
              @focus_class
            ]}
          >
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </button>
        </div>

        <div :if={!@review} id="review-list" phx-update="stream" class="space-y-3">
          <div
            id="no-reviews"
            class="hidden rounded-2xl border border-dashed border-base-content/30 bg-base-100 px-6 py-12 text-center only:block"
          >
            <.icon name="hero-check-badge" class="mx-auto size-8" />
            <h2 class="mt-4 text-lg font-semibold">No reviews yet</h2>
            <p class="mt-2 text-sm">A requested action will appear here when it needs a decision.</p>
          </div>
          <.link
            :for={{dom_id, review} <- @streams.reviews}
            id={dom_id}
            navigate={~p"/reviews/#{review.id}"}
            class={[
              "flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-base-content/20 bg-base-100 p-5 transition hover:shadow-sm",
              @focus_class
            ]}
          >
            <div class="min-w-0">
              <h2 class="font-semibold">{action_label(review.action)}</h2>
              <p class="mt-1 text-sm">
                Requested {Calendar.strftime(review.inserted_at, "%b %d, %H:%M UTC")}
              </p>
            </div>
            <span class="inline-flex items-center gap-2 text-sm"><.icon
              name={if review.status == :requested, do: "hero-clock", else: "hero-check-badge"}
              class="size-5"
            />{status_label(review.status)}</span>
          </.link>
        </div>

        <div
          :if={@review}
          id="review-detail"
          class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_19rem]"
        >
          <section
            aria-labelledby="review-target-heading"
            class="min-w-0 rounded-2xl border border-base-content/20 bg-base-100 p-5 sm:p-7"
          >
            <h2 id="review-target-heading" class="text-lg font-semibold">Proposed action</h2>
            <dl id="review-target" class="mt-5 space-y-5">
              <div :for={{key, value} <- target_entries(@review.target)}>
                <dt class="text-sm font-semibold">{field_label(key)}</dt>
                <dd class="mt-1 whitespace-pre-wrap break-words text-sm leading-6">
                  {format_value(value)}
                </dd>
              </div>
            </dl>
            <p :if={@review.target == %{}} id="review-target-missing" class="mt-4 text-sm">
              This request has no saved action details. Request a new review with its complete target.
            </p>
            <div :if={@artifact} class="mt-6 border-t border-base-content/20 pt-6">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <h3 class="font-semibold">Recorded patch</h3>
                <.link
                  id="review-artifact-download"
                  href={~p"/artifacts/#{@artifact.id}"}
                  class={["rounded-lg text-sm underline underline-offset-4", @focus_class]}
                >Download complete evidence</.link>
              </div>
              <pre
                id="review-patch"
                class="mt-4 max-h-[32rem] overflow-auto rounded-xl bg-base-200 p-4 text-sm leading-6"
                tabindex="0"
              >{@patch}</pre>
              <p class="mt-2 text-xs">
                Large patches may be shortened here. Download the complete recorded evidence.
              </p>
              <div id="review-exports" phx-update="stream" class="mt-5 space-y-3">
                <.link
                  :for={{dom_id, export} <- @streams.exports}
                  id={dom_id}
                  data-export-path={export.path}
                  href={~p"/artifacts/#{export.id}"}
                  class={[
                    "block rounded-xl border border-base-content/20 p-4 text-sm transition hover:bg-base-200",
                    @focus_class
                  ]}
                >
                  <span class="flex items-center gap-2 font-semibold"><.icon
                    name="hero-document-arrow-down"
                    class="size-5"
                  />{export.path}</span>
                  <span class="mt-2 block break-all font-mono text-xs">SHA256 {export.digest}</span>
                </.link>
              </div>
            </div>
            <p
              :if={@artifact_unavailable?}
              id="review-evidence-unavailable"
              role="alert"
              class="mt-6 flex items-start gap-2 rounded-xl border border-base-content/30 bg-base-200 p-4 text-sm"
            >
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
              Required patch evidence is unavailable to your account. Request access before approving.
            </p>
          </section>

          <aside
            aria-labelledby="review-decision-heading"
            class="rounded-2xl border border-base-content/20 bg-base-100 p-6"
          >
            <h2 id="review-decision-heading" class="text-lg font-semibold">Decision</h2>
            <p
              id="review-status"
              class="mt-4 flex items-center gap-2 text-sm"
              role="status"
              aria-live="polite"
            >
              <.icon name="hero-shield-check" class="size-5" />{if @expired? and
                                                                     @review.status == :requested,
                                                                   do: "Expired",
                                                                   else: status_label(@review.status)}
            </p>
            <p class="mt-3 text-sm">
              Expires
              <time datetime={DateTime.to_iso8601(@review.expires_at)}>{Calendar.strftime(
                @review.expires_at,
                "%b %d, %H:%M UTC"
              )}</time>
            </p>
            <div :if={@review.status == :requested} class="mt-6 flex flex-col gap-3">
              <button
                id="approve-review"
                type="button"
                phx-click="decide"
                phx-value-decision="approved"
                phx-disable-with="Approving..."
                disabled={!@decision_enabled?}
                class={[
                  "rounded-xl bg-base-content px-4 py-3 text-sm font-semibold text-base-100 transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-40",
                  @focus_class
                ]}
              >Approve this action</button>
              <button
                id="reject-review"
                type="button"
                phx-click="decide"
                phx-value-decision="rejected"
                phx-disable-with="Rejecting..."
                disabled={!@decision_enabled?}
                class={[
                  "rounded-xl border border-base-content/40 px-4 py-3 text-sm font-semibold transition hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-40",
                  @focus_class
                ]}
              >Reject this action</button>
              <p :if={!@decision_enabled?} id="review-decision-disabled" class="text-sm leading-6">
                A decision requires a current eligible reviewer, an unexpired request, and accessible evidence.
              </p>
            </div>
            <p
              :if={@decision_message}
              id="review-decision-message"
              class="mt-5 text-sm leading-6"
              role="status"
              aria-live="polite"
            >
              {@decision_message}
            </p>
            <details id="review-proof" class="mt-6 border-t border-base-content/20 pt-5 text-sm">
              <summary class={["cursor-pointer rounded-lg font-medium", @focus_class]}>
                Approval identity
              </summary>
              <p class="mt-3 break-all font-mono text-xs leading-5">{@review.target_digest}</p>
              <p class="mt-2">Policy revision {@review.policy_revision}</p>
            </details>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
