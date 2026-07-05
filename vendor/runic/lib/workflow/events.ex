defmodule Runic.Workflow.Events do
  @moduledoc """
  Barrel module for all workflow event types.

  Events are the primary mutation interface in the event-sourced workflow model.
  `Invokable.execute/2` produces events, and `Workflow.apply_event/2` folds them
  into the workflow graph as a pure function.

  Note: scattered elements from a fan-out and the result of a fan-in reduce are
  both plain `FactProduced` events (labelled `:fan_out` and `:reduced`
  respectively) — there are no bespoke fan-out/fan-in event types.
  """

  alias Runic.Workflow.Events.FactProduced
  alias Runic.Workflow.Events.ActivationConsumed
  alias Runic.Workflow.Events.RunnableActivated
  alias Runic.Workflow.Events.ConditionSatisfied
  alias Runic.Workflow.Events.StateInitiated
  alias Runic.Workflow.Events.JoinFactReceived
  alias Runic.Workflow.Events.JoinCompleted
  alias Runic.Workflow.Events.JoinEdgeRelabeled

  @type event ::
          FactProduced.t()
          | ActivationConsumed.t()
          | RunnableActivated.t()
          | ConditionSatisfied.t()
          | StateInitiated.t()
          | JoinFactReceived.t()
          | JoinCompleted.t()
          | JoinEdgeRelabeled.t()

  defdelegate fact_produced(), to: FactProduced, as: :__struct__
  defdelegate activation_consumed(), to: ActivationConsumed, as: :__struct__
  defdelegate runnable_activated(), to: RunnableActivated, as: :__struct__
  defdelegate condition_satisfied(), to: ConditionSatisfied, as: :__struct__
  defdelegate state_initiated(), to: StateInitiated, as: :__struct__
  defdelegate join_fact_received(), to: JoinFactReceived, as: :__struct__
  defdelegate join_completed(), to: JoinCompleted, as: :__struct__
  defdelegate join_edge_relabeled(), to: JoinEdgeRelabeled, as: :__struct__
end
