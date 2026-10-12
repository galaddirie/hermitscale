defmodule Hermitscale.Integrations.OpenAI.Client do
  @moduledoc "Synchronous OpenAI Responses requests using API keys vended by Pipes."
  alias Hermitscale.Integrations.Request
  @url "https://api.openai.com/v1/responses"

  @doc "Creates a completed response, retaining the API payload and adding output_text. Streaming and background requests are disabled."
  def create_response(credentials, params, opts \\ []) when is_map(params) do
    params =
      params
      |> Map.put_new("store", false)
      |> Map.put("stream", false)
      |> Map.put("background", false)

    opts =
      Application.get_env(:hermitscale, __MODULE__, [])
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(opts)
      |> Keyword.put_new(:receive_timeout, 120_000)
      |> Keyword.put(:json, params)

    with {:ok, body} <- Request.json(:post, @url, credentials, opts),
         {:ok, response} <- validate_response(body) do
      {:ok, response}
    end
  end

  defp validate_response(%{"id" => id, "status" => "completed", "output" => output} = response)
       when is_binary(id) and id != "" and is_list(output) do
    with {:ok, texts} <- output_texts(output) do
      {:ok, Map.put(response, "output_text", Enum.join(texts))}
    end
  end

  defp validate_response(%{"status" => status})
       when status in ["incomplete", "failed", "queued", "in_progress"],
       do: {:error, {:openai_response_not_completed, status}}

  defp validate_response(_response), do: {:error, :invalid_openai_response}

  defp output_texts(output) do
    Enum.reduce_while(output, {:ok, []}, fn
      %{"type" => "message", "content" => content}, {:ok, texts} when is_list(content) ->
        case content_texts(content) do
          {:ok, next} -> {:cont, {:ok, texts ++ next}}
          {:error, _reason} = error -> {:halt, error}
        end

      %{"type" => type}, acc when is_binary(type) and type != "message" ->
        {:cont, acc}

      _item, _acc ->
        {:halt, {:error, :invalid_openai_response}}
    end)
  end

  defp content_texts(content) do
    Enum.reduce_while(content, {:ok, []}, fn
      %{"type" => "output_text", "text" => text}, {:ok, texts} when is_binary(text) ->
        {:cont, {:ok, texts ++ [text]}}

      %{"type" => type}, acc when is_binary(type) and type != "output_text" ->
        {:cont, acc}

      _content, _acc ->
        {:halt, {:error, :invalid_openai_response}}
    end)
  end
end
