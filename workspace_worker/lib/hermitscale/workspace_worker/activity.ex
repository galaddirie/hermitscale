defmodule Hermitscale.WorkspaceWorker.Activity do
  @moduledoc "An expiring Sprite task hold bounded by the admitted lease's deadline."
  def acquire(deadline, config) do
    lease_id =
      config
      |> Keyword.fetch!(:lease_file)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("lease_id")

    remaining = max(min(DateTime.diff(deadline, DateTime.utc_now(), :second), 3600), 1)
    request = request()

    case Req.put(request, url: "/v1/tasks/hs-" <> lease_id, json: %{expire: "#{remaining}s"}) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        case Req.post(request,
               url: "/v1/tasks",
               json: %{name: "hs-" <> lease_id, expire: "#{remaining}s"}
             ) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          {:ok, _response} -> {:error, :activity_hold_unavailable}
          {:error, _reason} -> {:error, :activity_hold_unavailable}
        end

      {:ok, _response} ->
        {:error, :activity_hold_unavailable}

      {:error, _reason} ->
        {:error, :activity_hold_unavailable}
    end
  end

  def release(config) do
    lease_id =
      config
      |> Keyword.fetch!(:lease_file)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("lease_id")

    case Req.delete(request(), url: "/v1/tasks/hs-" <> lease_id) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, _response} -> {:error, :activity_hold_unavailable}
      {:error, _reason} -> {:error, :activity_hold_unavailable}
    end
  end

  defp request,
    do:
      Req.new(
        base_url: "http://sprite",
        unix_socket: "/.sprite/api.sock",
        retry: false,
        redirect: false,
        receive_timeout: 5000,
        connect_options: [timeout: 2000]
      )
end
