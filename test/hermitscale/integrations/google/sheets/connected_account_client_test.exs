defmodule Hermitscale.Integrations.Google.Sheets.ConnectedAccountClientTest do
  use Hermitscale.DataCase, async: false

  alias Hermitscale.Integrations.{ConnectedAccounts, CredentialRef}
  alias Hermitscale.Integrations.Google.Sheets.Client, as: SheetsClient
  alias Hermitscale.WorkOSTest.Client, as: WorkOSClient

  import Hermitscale.AccountsFixtures

  @read_scope "https://www.googleapis.com/auth/spreadsheets.readonly"

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    start_supervised!({WorkOSClient, %{}})
    previous = Application.get_env(:hermitscale, ConnectedAccounts, [])

    Application.put_env(
      :hermitscale,
      ConnectedAccounts,
      Keyword.put(previous, :client, WorkOSClient)
    )

    on_exit(fn -> Application.put_env(:hermitscale, ConnectedAccounts, previous) end)
  end

  test "keeps only an opaque reference in run context and vends on every immediate request" do
    user = user_fixture()
    scope = user_scope_fixture(user)

    account =
      connected_account_fixture(user, scope.organization, granted_scopes: [@read_scope])

    assert {:ok, %CredentialRef{} = reference} =
             ConnectedAccounts.credential_ref(
               scope.organization.id,
               "google.oauth",
               account.id,
               [@read_scope]
             )

    refute Map.has_key?(Map.from_struct(reference), :access_token)
    refute inspect(reference) =~ "provider-secret"

    WorkOSClient.put_response(
      :fetch_oauth_token,
      {:ok,
       %{
         access_token: "provider-secret",
         expires_at: nil,
         scopes: [@read_scope],
         missing_scopes: []
       }}
    )

    Req.Test.expect(__MODULE__, 2, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer provider-secret"]
      Req.Test.json(conn, %{"values" => [["ready"]]})
    end)

    for _request <- 1..2 do
      assert {:ok, %{"values" => [["ready"]]}} =
               SheetsClient.read_rows(
                 reference,
                 "sheet_123",
                 "Sheet1!A:B",
                 plug: {Req.Test, __MODULE__}
               )
    end

    vend_calls =
      WorkOSClient.calls()
      |> Enum.filter(fn {operation, _args} -> operation == :fetch_oauth_token end)

    assert length(vend_calls) == 2
  end
end
