defmodule Hermitscale.Triggers.Runtime.Callback do
  @moduledoc false

  require Logger

  # Source callbacks are extension points. A defect must remain visible, but
  # restarting the same persisted source would repeat it under the supervisor.
  def invoke(module, callback, args) do
    apply(module, callback, args)
  rescue
    exception ->
      stacktrace = Enum.map(__STACKTRACE__, &without_arguments/1)

      Logger.error(
        "Trigger callback #{inspect(module)}.#{callback} raised #{inspect(exception.__struct__)}\n" <>
          Exception.format_stacktrace(stacktrace),
        source_module: module,
        source_callback: callback
      )

      {:callback_failed, {:source_callback_failed, callback}}
  end

  defp without_arguments({module, function, args, location}) when is_list(args),
    do: {module, function, length(args), location}

  defp without_arguments({module, function, arity, location}) when is_integer(arity),
    do: {module, function, arity, location}
end
