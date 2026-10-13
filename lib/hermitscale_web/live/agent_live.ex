defmodule HermitscaleWeb.AgentLive do
  @moduledoc "Authenticated conversations with durable, streamed turn and event history."
  use HermitscaleWeb, :live_view

  alias Hermitscale.{Agents, Authorization}

  @history_page_size 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Conversations")
     |> assign(:conversation, nil)
     |> assign(:history_empty?, true)
     |> assign(:turn_oldest_sequence, nil)
     |> assign(:event_oldest_sequence, nil)
     |> assign(:event_newest_sequence, 0)
     |> assign(:more_turns?, false)
     |> assign(:more_events?, false)
     |> assign(
       :can_run?,
       Authorization.authorize(socket.assigns.current_scope, "agents:run") == :ok
     )
     |> assign(
       :new_session_form,
       to_form(Agents.change_session(socket.assigns.current_scope), as: :session)
     )
     |> assign(:turn_form, nil)
     |> assign(:operation_key, Ecto.UUID.generate())
     |> assign(:publication_form, publication_form(%{}))
     |> assign(:connections_loaded?, false)
     |> assign(:openai_accounts, [])
     |> assign(:github_accounts, [])
     |> assign(
       :can_publish?,
       Authorization.authorize(socket.assigns.current_scope, "agents:publish") == :ok
     )
     |> stream(:sessions, [], dom_id: &"agent-sessions-#{&1.id}")
     |> stream(:turns, [], dom_id: &"agent-turns-#{&1.id}")
     |> stream(:events, [], dom_id: &"agent-events-#{&1.id}")}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    case Agents.list_sessions(socket.assigns.current_scope) do
      sessions when is_list(sessions) ->
        {:noreply, stream(socket, :sessions, sessions, reset: true)}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "Your workspace role does not allow viewing conversations.")}
    end
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    with {:ok, conversation} <- Agents.get_session(socket.assigns.current_scope, id) do
      if connected?(socket), do: Agents.subscribe(socket.assigns.current_scope, id)

      {:noreply,
       socket
       |> assign(:conversation, conversation)
       |> assign(:page_title, conversation.title)
       |> assign_turn_form(%{})
       |> refresh_history(reset: true)}
    else
      {:error, reason} when reason in [:not_found, :forbidden] ->
        {:noreply,
         socket
         |> put_flash(:error, "This conversation is unavailable.")
         |> push_navigate(to: ~p"/agents")}
    end
  end

  @impl true
  def handle_event("validate_session", %{"session" => params}, socket) do
    form =
      socket.assigns.current_scope
      |> Agents.change_session(params)
      |> to_form(as: :session, action: :validate)

    {:noreply, assign(socket, :new_session_form, form)}
  end

  def handle_event("load_connections", _params, socket) do
    case Hermitscale.Integrations.ConnectedAccounts.list(socket.assigns.current_scope) do
      {:ok, accounts} ->
        options = fn provider ->
          accounts
          |> Enum.filter(&(&1["provider"] == provider and &1["state"] == "connected"))
          |> Enum.map(&{&1["account_display_name"] || &1["id"], &1["id"]})
        end

        {:noreply,
         assign(socket,
           connections_loaded?: true,
           openai_accounts: options.("openai"),
           github_accounts: options.("github")
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Connected accounts could not be loaded: " <> inspect(reason))}
    end
  end

  def handle_event("start_session", %{"session" => params}, socket) do
    with {:ok, conversation} <- Agents.start_session(socket.assigns.current_scope, params) do
      {:noreply, push_navigate(socket, to: ~p"/agents/#{conversation.id}")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :new_session_form, to_form(changeset, as: :session, action: :insert))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, operation_error(reason))}
    end
  end

  def handle_event("validate_turn", %{"turn" => params}, socket) do
    {:noreply, assign_turn_form(socket, params, action: :validate)}
  end

  def handle_event("submit_turn", %{"turn" => params}, socket) do
    with {:ok, _turn} <-
           Agents.submit_turn(
             socket.assigns.current_scope,
             socket.assigns.conversation.id,
             params
           ) do
      {:noreply,
       socket
       |> assign(:operation_key, Ecto.UUID.generate())
       |> assign_turn_form(%{})
       |> refresh_history()}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :turn_form, to_form(changeset, as: :turn, action: :insert))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, operation_error(reason))}
    end
  end

  def handle_event("cancel_turn", %{"id" => id}, socket) do
    with {:ok, turn} <- Agents.cancel_turn(socket.assigns.current_scope, id) do
      {:noreply, socket |> stream_insert(:turns, turn) |> refresh_history()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, operation_error(reason))}
    end
  end

  def handle_event("archive_session", _params, socket), do: set_session_status(socket, :archived)

  def handle_event("approve_turn", %{"id" => id}, socket),
    do: answer_approval(socket, id, :approved)

  def handle_event("deny_turn", %{"id" => id}, socket), do: answer_approval(socket, id, :rejected)
  def handle_event("reopen_session", _params, socket), do: set_session_status(socket, :open)

  def handle_event("publish_branch", %{"publication" => params}, socket) do
    form = publication_form(params)

    if form.source.valid? do
      case Agents.publish_branch(
             socket.assigns.current_scope,
             socket.assigns.conversation.id,
             params
           ) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:publication_form, publication_form(%{}))
           |> put_flash(:info, "Published branch at " <> result["commit_sha"])
           |> refresh_history()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, operation_error(reason))}
      end
    else
      {:noreply, assign(socket, :publication_form, form)}
    end
  end

  def handle_event("older_turns", _params, socket) do
    turns =
      socket.assigns.current_scope
      |> Agents.list_turns(socket.assigns.conversation.id,
        before_admission_sequence: socket.assigns.turn_oldest_sequence,
        limit: @history_page_size
      )

    {:noreply,
     socket
     |> assign(
       :turn_oldest_sequence,
       oldest_sequence(turns, :admission_sequence, socket.assigns.turn_oldest_sequence)
     )
     |> assign(:more_turns?, length(turns) == @history_page_size)
     |> stream(:turns, turns, at: 0)}
  end

  def handle_event("older_events", _params, socket) do
    events =
      Agents.list_events(socket.assigns.current_scope, socket.assigns.conversation.id,
        before_sequence: socket.assigns.event_oldest_sequence,
        limit: @history_page_size
      )

    {:noreply,
     socket
     |> assign(
       :event_oldest_sequence,
       oldest_sequence(events, :sequence, socket.assigns.event_oldest_sequence)
     )
     |> assign(:more_events?, length(events) == @history_page_size)
     |> stream(:events, Enum.reverse(events), at: 0)}
  end

  @impl true
  def handle_info({:agent_session_updated, id}, %{assigns: %{conversation: %{id: id}}} = socket) do
    with {:ok, conversation} <- Agents.get_session(socket.assigns.current_scope, id) do
      {:noreply, socket |> assign(:conversation, conversation) |> refresh_history()}
    else
      {:error, reason} when reason in [:not_found, :forbidden] ->
        {:noreply,
         socket
         |> put_flash(:error, "This conversation is unavailable.")
         |> push_navigate(to: ~p"/agents")}
    end
  end

  def handle_info(
        {:agent_turn_updated, session_id, turn_id},
        %{assigns: %{conversation: %{id: session_id}}} = socket
      ) do
    with {:ok, turn} <- Agents.get_turn(socket.assigns.current_scope, turn_id) do
      socket =
        if socket.assigns.turn_oldest_sequence != nil and
             turn.admission_sequence >= socket.assigns.turn_oldest_sequence do
          stream_insert(socket, :turns, turn)
        else
          socket
        end

      {:noreply, socket}
    else
      {:error, reason} when reason in [:forbidden, :not_found] -> {:noreply, socket}
    end
  end

  defp set_session_status(socket, status) do
    with {:ok, conversation} <-
           Agents.update_session(
             socket.assigns.current_scope,
             socket.assigns.conversation.id,
             status
           ) do
      {:noreply, assign(socket, :conversation, conversation)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, operation_error(reason))}
    end
  end

  defp answer_approval(socket, id, decision) do
    case Agents.answer_approval(socket.assigns.current_scope, id, decision) do
      {:ok, turn} -> {:noreply, socket |> stream_insert(:turns, turn) |> refresh_history()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, operation_error(reason))}
    end
  end

  defp assign_turn_form(socket, params, opts \\ []) do
    params = Map.put_new(params, "operation_key", socket.assigns.operation_key)

    form =
      socket.assigns.current_scope
      |> Agents.change_turn(socket.assigns.conversation.id, params)
      |> to_form(Keyword.merge([as: :turn], opts))

    assign(socket, :turn_form, form)
  end

  defp refresh_history(socket, opts \\ []) do
    scope = socket.assigns.current_scope
    id = socket.assigns.conversation.id
    {:ok, conversation} = Agents.get_session(scope, id)
    turns = Agents.list_turns(scope, id, limit: @history_page_size)
    reset? = Keyword.get(opts, :reset, false)

    events =
      if reset? do
        Agents.list_events(scope, id,
          before_sequence: conversation.last_event_sequence + 1,
          limit: @history_page_size
        )
      else
        Agents.list_events(scope, id,
          after_sequence: socket.assigns.event_newest_sequence,
          limit: 200
        )
      end

    socket =
      if reset? do
        socket
        |> assign(:turn_oldest_sequence, oldest_sequence(turns, :admission_sequence, nil))
        |> assign(:event_oldest_sequence, oldest_sequence(events, :sequence, nil))
        |> assign(:more_turns?, length(turns) == @history_page_size)
        |> assign(:more_events?, length(events) == @history_page_size)
      else
        socket
      end

    socket
    |> assign(:conversation, conversation)
    |> assign(
      :turn_oldest_sequence,
      socket.assigns.turn_oldest_sequence || oldest_sequence(turns, :admission_sequence, nil)
    )
    |> assign(
      :event_oldest_sequence,
      socket.assigns.event_oldest_sequence || oldest_sequence(events, :sequence, nil)
    )
    |> assign(
      :event_newest_sequence,
      newest_sequence(events, socket.assigns.event_newest_sequence)
    )
    |> assign(:history_empty?, turns == [])
    |> stream(:turns, Enum.reverse(turns), reset: reset?)
    |> stream(:events, events, reset: reset?)
  end

  defp oldest_sequence([], _field, previous), do: previous

  defp oldest_sequence(items, field, _previous),
    do: items |> Enum.map(&Map.fetch!(&1, field)) |> Enum.min()

  defp newest_sequence([], previous), do: previous
  defp newest_sequence(events, _previous), do: events |> Enum.map(& &1.sequence) |> Enum.max()

  defp publication_form(params) do
    params = Map.put_new(params, "operation_key", Ecto.UUID.generate())

    {%{}, %{operation_key: :string, branch: :string, message: :string}}
    |> Ecto.Changeset.cast(params, [:operation_key, :branch, :message])
    |> Ecto.Changeset.validate_required([:operation_key, :branch, :message])
    |> Ecto.Changeset.validate_length(:message, max: 4096)
    |> to_form(as: :publication)
  end

  defp operation_error(:forbidden), do: "Your workspace role does not allow this action."
  defp operation_error(:not_found), do: "This conversation is unavailable."
  defp operation_error(:session_not_open), do: "Reopen this conversation before adding a turn."

  defp operation_error(:turn_in_progress),
    do: "Wait for the current turn or stop it before continuing."

  defp operation_error(:operation_key_conflict),
    do:
      "This request has already been submitted with different content. Reload the conversation and try again."

  defp operation_error(:session_closed), do: "This conversation is closed and cannot be reopened."

  defp operation_error(:execution_actor_ineligible),
    do: "Your workspace membership changed. Sign in again before continuing."

  defp operation_error(_reason), do: "The action could not be completed. Please try again."

  defp status_label(:queued), do: "Queued"
  defp status_label(:succeeded), do: "Completed"
  defp status_label(:waiting_for_approval), do: "Waiting for permission"

  defp status_label(status),
    do: status |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp cancellable?(turn),
    do: not Agents.Turn.terminal?(turn) and is_nil(turn.cancellation_requested_at)

  defp event_message(%{type: "branch.published", payload: %{"result" => result}}),
    do: result["branch"] <> " · " <> result["commit_sha"]

  defp event_message(%{payload: payload}) do
    payload
    |> Map.take(["message", "summary", "reason", "status"])
    |> Enum.map_join(" · ", fn {_key, value} -> event_value(value) end)
  end

  defp event_value("execution_actor_ineligible"), do: "Workspace membership changed."
  defp event_value("deadline_exceeded"), do: "The task's time limit was reached."
  defp event_value(value) when is_binary(value), do: value
  defp event_value(value) when is_number(value), do: to_string(value)
  defp event_value(_value), do: ""

  defp result_summary(%{"summary" => summary}) when is_binary(summary), do: summary
  defp result_summary(%{"result" => %{"summary" => summary}}) when is_binary(summary), do: summary
  defp result_summary(_result), do: ""

  defp result_checks(%{"checks" => checks}) when is_list(checks), do: checks
  defp result_checks(_result), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl">
        <%= if @live_action == :index do %>
          <div class="grid gap-10 lg:grid-cols-[1fr_360px]">
            <section aria-labelledby="conversations-heading">
              <div class="mb-6 flex items-end justify-between gap-4">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-[0.2em] text-base-content/55">
                    Your workspace
                  </p>
                  <h1 id="conversations-heading" class="mt-2 text-3xl font-semibold tracking-tight">
                    Conversations
                  </h1>
                  <p class="mt-3 max-w-lg text-sm leading-6 text-base-content/65">
                    Start a task, keep its history, and return when you’re ready to continue.
                  </p>
                </div>
                <.icon name="hero-chat-bubble-left-right" class="mb-1 size-8 text-base-content/35" />
              </div>

              <div id="agent-sessions" phx-update="stream" class="space-y-3">
                <div
                  id="no-conversations"
                  class="hidden rounded-2xl border border-dashed border-base-300 px-6 py-12 text-center only:block"
                >
                  <.icon name="hero-sparkles" class="mx-auto size-7 text-base-content/40" />
                  <p class="mt-4 font-medium">Make room for your next idea.</p>
                  <p class="mt-2 text-sm text-base-content/60">
                    Your first conversation will appear here.
                  </p>
                </div>
                <.link
                  :for={{dom_id, conversation} <- @streams.sessions}
                  id={dom_id}
                  navigate={~p"/agents/#{conversation.id}"}
                  class="group flex items-center justify-between gap-4 rounded-2xl border border-base-300 bg-base-100 p-5 transition duration-150 hover:border-primary/40 hover:shadow-sm focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-primary"
                >
                  <div class="min-w-0">
                    <h2 class="truncate font-semibold">{conversation.title}</h2>
                    <p class="mt-1 text-xs text-base-content/55">
                      {status_label(conversation.status)}
                    </p>
                  </div>
                  <.icon
                    name="hero-arrow-up-right"
                    class="size-5 text-base-content/35 transition group-hover:text-primary"
                  />
                </.link>
              </div>
            </section>

            <section
              :if={@can_run?}
              class="self-start rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm"
              aria-labelledby="new-conversation-heading"
            >
              <h2 id="new-conversation-heading" class="text-lg font-semibold">
                Start a conversation
              </h2>
              <p class="mb-6 mt-2 text-sm leading-6 text-base-content/60">
                Give your work a name. You can add a repository at the start.
              </p>
              <.form
                for={@new_session_form}
                id="new-conversation-form"
                phx-change="validate_session"
                phx-submit="start_session"
                class="space-y-4"
              >
                <.input
                  field={@new_session_form[:title]}
                  label="Conversation name"
                  placeholder="What are you working on?"
                  maxlength="160"
                  required
                />
                <.input
                  field={@new_session_form[:repository]}
                  label="Repository (optional)"
                  placeholder="owner/repository"
                />
                <.input
                  field={@new_session_form[:base_sha]}
                  label="Base commit (optional)"
                  placeholder="Full 40-character commit SHA"
                  maxlength="40"
                />
                <button
                  id="start-conversation"
                  type="submit"
                  phx-disable-with="Creating…"
                  class="btn btn-primary w-full"
                >Create conversation <.icon name="hero-arrow-right" class="size-4" /></button>
                <.input
                  field={@new_session_form[:operation_key]}
                  type="hidden"
                  value={@operation_key}
                />
                <button
                  :if={not @connections_loaded?}
                  id="load-coding-connections"
                  type="button"
                  phx-click="load_connections"
                  phx-disable-with="Loading…"
                  class="btn btn-ghost btn-sm w-full"
                >Choose connected accounts</button>
                <%= if @connections_loaded? do %>
                  <.input
                    field={@new_session_form[:openai_account_id]}
                    type="select"
                    label="Coding account"
                    prompt="Use the only eligible account"
                    options={@openai_accounts}
                  />
                  <.input
                    field={@new_session_form[:github_account_id]}
                    type="select"
                    label="GitHub account"
                    prompt="Use the only eligible account"
                    options={@github_accounts}
                  />
                <% end %>
              </.form>
            </section>
          </div>
        <% else %>
          <%= if @conversation do %>
            <.link
              navigate={~p"/agents"}
              id="back-to-conversations"
              class="mb-6 inline-flex items-center gap-2 text-sm text-base-content/60 transition hover:text-base-content"
            ><.icon name="hero-arrow-left" class="size-4" /> Conversations</.link>
            <div class="grid gap-8 lg:grid-cols-[1fr_280px]">
              <section class="min-w-0" aria-labelledby="conversation-heading">
                <div class="mb-8 flex flex-wrap items-start justify-between gap-4">
                  <h1 id="conversation-heading" class="text-3xl font-semibold tracking-tight">
                    {@conversation.title}
                  </h1>
                  <span id="conversation-status" class="badge badge-outline">{status_label(
                    @conversation.status
                  )}</span>
                </div>

                <p
                  :if={@history_empty?}
                  id="empty-turn-history"
                  class="mb-8 rounded-2xl border border-dashed border-base-300 p-8 text-center text-sm leading-6 text-base-content/60"
                >
                  Describe the outcome you want. Work continues when you close this page, and the same workspace is retained for follow-ups.
                </p>

                <button
                  :if={@more_turns?}
                  id="load-older-turns"
                  type="button"
                  phx-click="older_turns"
                  phx-disable-with="Loading…"
                  class="btn btn-ghost btn-sm mb-4"
                >Load older requests</button>
                <div id="agent-turns" phx-update="stream" class="mb-8 space-y-4">
                  <article
                    :for={{dom_id, turn} <- @streams.turns}
                    id={dom_id}
                    class="rounded-2xl border border-base-300 bg-base-100 p-5"
                  >
                    <div class="flex items-center justify-between gap-3">
                      <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">Your request</span>
                      <span
                        id={"turn-status-#{turn.id}"}
                        class="text-xs font-medium text-base-content/65"
                        role="status"
                      >{status_label(turn.status)}</span>
                    </div>
                    <p class="mt-4 whitespace-pre-wrap break-words text-sm leading-7">
                      {turn.instructions}
                    </p>
                    <div class="mt-4 flex items-center justify-between gap-4 border-t border-base-200 pt-3 text-xs text-base-content/55">
                      <span>Limit: {turn.timeout_seconds} seconds</span>
                      <button
                        :if={@can_run? and cancellable?(turn)}
                        id={"stop-turn-#{turn.id}"}
                        type="button"
                        phx-click="cancel_turn"
                        phx-value-id={turn.id}
                        phx-disable-with="Stopping…"
                        class="btn btn-ghost btn-xs"
                      >Stop</button>
                      <span
                        :if={turn.cancellation_requested_at && not Agents.Turn.terminal?(turn)}
                        role="status"
                      >Stop requested</span>
                    </div>
                    <div
                      :if={turn.approval_id && turn.status == :waiting_for_approval}
                      id={"approval-#{turn.id}"}
                      class="mt-4 rounded-xl border border-amber-300 bg-amber-50 p-4 text-amber-950"
                    >
                      <p class="font-semibold">Permission requested</p>
                      <pre class="mt-2 overflow-auto whitespace-pre-wrap text-xs">{Jason.encode!(Map.get(turn.runtime_state,"approval_request",%{}),pretty: true)}</pre>
                      <div
                        :if={@can_run?}
                        class="mt-3 flex gap-2"
                      >
                        <button
                          id={"approve-turn-#{turn.id}"}
                          type="button"
                          phx-click="approve_turn"
                          phx-value-id={turn.id}
                          phx-disable-with="Approving…"
                          class="btn btn-primary btn-sm"
                        >Approve</button>
                        <button
                          id={"deny-turn-#{turn.id}"}
                          type="button"
                          phx-click="deny_turn"
                          phx-value-id={turn.id}
                          phx-disable-with="Denying…"
                          class="btn btn-ghost btn-sm"
                        >Deny</button>
                      </div>
                    </div>
                    <div
                      :if={turn.result}
                      id={"result-#{turn.id}"}
                      class="mt-4 border-t border-base-200 pt-4 text-sm"
                    >
                      <p class="whitespace-pre-wrap">{result_summary(turn.result)}</p>
                      <ul class="mt-3 space-y-1">
                        <li
                          :for={check <- result_checks(turn.result)}
                          class="flex items-center gap-2"
                        >
                          <.icon
                            name={
                              if(check["exit_code"] == 0,
                                do: "hero-check-circle",
                                else: "hero-x-circle"
                              )
                            }
                            class={[
                              "size-4",
                              if(check["exit_code"] == 0, do: "text-success", else: "text-error")
                            ]}
                          />{check["name"]} · exit {check[
                            "exit_code"
                          ]}
                        </li>
                      </ul>
                    </div>
                  </article>
                </div>

                <.form
                  :if={@can_run? and @conversation.status == :open}
                  for={@turn_form}
                  id="turn-form"
                  phx-change="validate_turn"
                  phx-submit="submit_turn"
                  class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
                >
                  <.input field={@turn_form[:operation_key]} type="hidden" />
                  <.input
                    field={@turn_form[:instructions]}
                    type="textarea"
                    label="Your next task"
                    placeholder="Describe the outcome you want and any constraints…"
                    rows="4"
                    maxlength="32000"
                    required
                  />
                  <details class="mb-5 text-sm text-base-content/65">
                    <summary class="cursor-pointer py-2">Task limits</summary>
                    <div class="mt-3 grid gap-4 sm:grid-cols-2">
                      <.input
                        field={@turn_form[:timeout_seconds]}
                        type="number"
                        label="Time limit (seconds)"
                        min="30"
                        max="3600"
                        required
                      />
                    </div>
                  </details>
                  <div class="flex flex-wrap items-center justify-between gap-3">
                    <p class="text-xs leading-5 text-base-content/55">
                      Runs within your time limit. Workspace files are retained after completion.
                    </p>
                    <button
                      id="submit-turn"
                      type="submit"
                      phx-disable-with="Saving…"
                      class="btn btn-primary btn-sm"
                    >Run task <.icon name="hero-arrow-up" class="size-4" /></button>
                  </div>
                </.form>
                <p
                  :if={not @can_run?}
                  id="conversation-permission-read-only"
                  class="rounded-xl border border-base-300 p-5 text-sm text-base-content/60"
                >
                  Your workspace role allows viewing this conversation.
                </p>
                <p
                  :if={@conversation.status != :open}
                  id="conversation-read-only"
                  class="rounded-xl border border-base-300 p-5 text-sm text-base-content/60"
                >
                  This conversation is {status_label(@conversation.status) |> String.downcase()}. Reopen it to add a request.
                </p>
              </section>

              <aside class="space-y-5">
                <section
                  :if={@can_publish? and @conversation.repository != nil}
                  class="rounded-2xl border border-base-300 p-5"
                >
                  <h2 class="text-sm font-semibold">Publish changes</h2>
                  <.form
                    for={@publication_form}
                    id="publication-form"
                    phx-submit="publish_branch"
                    class="mt-4"
                  >
                    <.input field={@publication_form[:operation_key]} type="hidden" />
                    <.input field={@publication_form[:branch]} label="New branch" required />
                    <.input field={@publication_form[:message]} label="Commit message" required />
                    <button
                      id="publish-branch"
                      class="btn btn-primary btn-sm w-full"
                      phx-disable-with="Publishing…"
                    >Publish branch</button>
                  </.form>
                </section>
                <section
                  class="rounded-2xl border border-base-300 p-5"
                  aria-labelledby="workspace-heading"
                >
                  <h2 id="workspace-heading" class="text-sm font-semibold">Workspace</h2>
                  <dl class="mt-4 space-y-4 text-xs">
                    <div>
                      <dt class="text-base-content/50">Repository</dt><dd class="mt-1 break-all font-medium">
                        {@conversation.repository || "No repository selected"}
                      </dd>
                    </div>
                    <div :if={@conversation.base_sha}>
                      <dt class="text-base-content/50">Base commit</dt><dd class="mt-1 break-all font-mono">
                        {@conversation.base_sha}
                      </dd>
                    </div>
                    <div>
                      <dt class="text-base-content/50">Workspace record</dt><dd class="mt-1 break-all font-mono text-base-content/70">
                        {@conversation.workspace_id}
                      </dd>
                    </div>
                  </dl>
                  <p class="mt-5 border-t border-base-200 pt-4 text-xs leading-6 text-base-content/55">
                    History is retained separately from activity. Archiving keeps this conversation and its workspace record.
                  </p>
                  <button
                    :if={@can_run? and @conversation.status == :open}
                    id="archive-conversation"
                    type="button"
                    phx-click="archive_session"
                    phx-disable-with="Archiving…"
                    class="btn btn-ghost btn-sm mt-4 w-full"
                  >Archive conversation</button>
                  <button
                    :if={@can_run? and @conversation.status == :archived}
                    id="reopen-conversation"
                    type="button"
                    phx-click="reopen_session"
                    phx-disable-with="Reopening…"
                    class="btn btn-outline btn-sm mt-4 w-full"
                  >Reopen conversation</button>
                </section>

                <section aria-labelledby="activity-heading">
                  <h2
                    id="activity-heading"
                    class="mb-3 px-1 text-xs font-semibold uppercase tracking-wider text-base-content/50"
                  >
                    Recorded activity
                  </h2>
                  <button
                    :if={@more_events?}
                    id="load-older-events"
                    type="button"
                    phx-click="older_events"
                    phx-disable-with="Loading…"
                    class="btn btn-ghost btn-xs mb-3"
                  >Load older activity</button>
                  <div id="agent-events" phx-update="stream" class="space-y-3">
                    <p
                      id="no-agent-events"
                      class="hidden px-1 text-xs leading-6 text-base-content/50 only:block"
                    >
                      Activity will appear as requests change state.
                    </p>
                    <div
                      :for={{dom_id, event} <- @streams.events}
                      id={dom_id}
                      class="rounded-xl border border-base-300 p-3 text-xs"
                    >
                      <p class="font-medium">
                        {event.type
                        |> String.replace(".", " ")
                        |> String.replace("_", " ")
                        |> String.capitalize()}
                      </p>
                      <p class="mt-1 break-words leading-5 text-base-content/55">
                        {event_message(event)}
                      </p>
                    </div>
                  </div>
                </section>
              </aside>
            </div>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
