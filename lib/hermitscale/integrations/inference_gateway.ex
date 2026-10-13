defmodule Hermitscale.Integrations.InferenceGateway do
  @moduledoc "Fixed-destination Responses proxy with expiring authority and measured usage."
  alias Hermitscale.Integrations.{ExecutionAccess, ConnectedAccounts, Request}
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Usage

  def request(token, params, opts \\ [])

  def request(token, params, opts) when is_map(params) do
    with :ok <- validate_request(params),
         {:ok, scope, cap} <- ExecutionAccess.authenticate(token, "inference", "responses"),
         model when is_binary(model) <- params["model"],
         true <- model in cap.models,
         {:ok, rates} <- rates(model),
         {:ok, _turn} <- Hermitscale.Agents.get_turn(scope, cap.operation_id),
         {:ok, ref} <-
           ConnectedAccounts.credential_ref(
             Scope.execution_context(scope, ["agents:run"]),
             cap.connection,
             []
           ),
         params =
           Map.put(
             params,
             "max_output_tokens",
             min(Map.get(params, "max_output_tokens", 8192), 8192)
           ),
         reserved = price(byte_size(Jason.encode!(params)), params["max_output_tokens"], rates),
         {:ok, _} <- ExecutionAccess.consume(cap, reserved) do
      case Request.request(
             :post,
             "https://api.openai.com/v1/responses",
             ref,
             Keyword.merge([json: params, retry: false, receive_timeout: 120_000], opts)
           ) do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          case usage(response.body) do
            {:ok, id, input, output} ->
              actual = price(input, output, rates)

              with {:ok, _} <-
                     Usage.record(scope, %{
                       operation_id: cap.operation_id,
                       category: :model,
                       deduplication_key: "openai:" <> id,
                       quantity: input + output,
                       cost_micros: actual,
                       rate_version: rates.version
                     }),
                   {:ok, _} <- ExecutionAccess.refund(cap, max(reserved - actual, 0)) do
                {:ok, response}
              end

            {:error, _} = error ->
              error
          end

        {:ok, %Req.Response{status: status}} when status in 400..499 ->
          ExecutionAccess.refund(cap, reserved)
          {:error, {:model_request_failed, status}}

        {:ok, %Req.Response{}} ->
          {:error, :inference_outcome_uncertain}

        {:error, _} ->
          {:error, :inference_outcome_uncertain}
      end
    else
      nil -> {:error, :invalid_model_request}
      false -> {:error, :model_not_allowed}
      {:error, _} = error -> error
    end
  end

  def request(_token, _params, _opts), do: {:error, :invalid_model_request}

  defp validate_request(params) do
    output = Map.get(params, "max_output_tokens", 8192)

    if is_integer(output) and output > 0 and byte_size(Jason.encode!(params)) <= 1_048_576,
      do: validate_text_request(params),
      else: {:error, :invalid_model_request}
  end

  defp validate_text_request(params) do
    tools = Map.get(params, "tools", [])

    if not is_list(tools) or length(tools) > 128 or
         Enum.any?(~w(previous_response_id conversation), &(Map.get(params, &1) != nil)) or
         external_input?(params["input"]) or
         not Enum.all?(tools, &allowed_tool?/1) do
      {:error, :unsupported_model_input}
    else
      :ok
    end
  end

  defp allowed_tool?(%{"type" => "namespace", "name" => name, "tools" => tools})
       when is_binary(name) and byte_size(name) in 1..128 and
              is_list(tools) and tools != [] and length(tools) <= 128,
       do: Enum.all?(tools, &local_tool?/1)

  defp allowed_tool?(tool), do: local_tool?(tool)

  defp local_tool?(%{"type" => type}) when type in ["function", "custom"], do: true
  defp local_tool?(_tool), do: false

  defp external_input?(map) when is_map(map),
    do:
      map["type"] in ~w(input_image input_file input_audio input_video item_reference) or
        Enum.any?(Map.values(map), &external_input?/1)

  defp external_input?(list) when is_list(list), do: Enum.any?(list, &external_input?/1)
  defp external_input?(_value), do: false

  def rates(model) do
    config = Application.get_env(:hermitscale, __MODULE__, [])

    case Map.fetch(Keyword.get(config, :rates, %{}), model) do
      {:ok,
       %{input_micros_per_million: input, output_micros_per_million: output, version: version} =
           rate}
      when is_integer(input) and input > 0 and is_integer(output) and output > 0 and
             is_binary(version) ->
        {:ok, rate}

      _missing_rate ->
        {:error, :model_rate_not_configured}
    end
  end

  defp price(input, output, r),
    do:
      div(
        input * r.input_micros_per_million + output * r.output_micros_per_million + 999_999,
        1_000_000
      )

  defp usage(%{"id" => id, "usage" => %{"input_tokens" => input, "output_tokens" => output}})
       when is_binary(id) and is_integer(input) and input >= 0 and is_integer(output) and
              output >= 0,
       do: {:ok, id, input, output}

  defp usage(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value({:error, :usage_evidence_missing}, fn line ->
      case String.starts_with?(line, "data: ") and
             Jason.decode(String.trim_leading(line, "data: ")) do
        {:ok, %{"type" => "response.completed", "response" => response}} -> usage(response)
        _other_stream_event -> nil
      end
    end)
  end

  defp usage(_body), do: {:error, :usage_evidence_missing}
end
