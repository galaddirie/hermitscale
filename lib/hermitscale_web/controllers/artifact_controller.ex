defmodule HermitscaleWeb.ArtifactController do
  use HermitscaleWeb, :controller

  def show(conn, %{"id" => id}) do
    case Hermitscale.Artifacts.get(conn.assigns.current_scope, id) do
      {:ok, artifact} ->
        conn
        |> put_resp_content_type(artifact.content_type)
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"artifact-" <> artifact.id <> "\""
        )
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, artifact.content)

      {:error, _} ->
        send_resp(conn, 404, "Artifact unavailable")
    end
  end
end
