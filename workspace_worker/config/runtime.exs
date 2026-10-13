import Config

case System.get_env("WORKSPACE_WORKER_ENABLED", "false") do
  "false" ->
    :ok

  "true" ->
    env = System.fetch_env!("WORKSPACE_PROVIDER_ENV_FILE") |> File.read!() |> JSON.decode!()
    allowed = ~w(PATH HOME OPENAI_API_KEY CODEX_HOME)

    true =
      is_map(env) and Enum.all?(env, fn {key, value} -> key in allowed and is_binary(value) end)

    token = System.fetch_env!("WORKSPACE_CONTROL_TOKEN_FILE") |> File.read!() |> String.trim()

    config :workspace_worker,
      enabled: true,
      service: [
        workspace_id: System.fetch_env!("WORKSPACE_ID"),
        journal_path: System.fetch_env!("WORKSPACE_JOURNAL_PATH"),
        socket_path: System.fetch_env!("WORKSPACE_CONTROL_SOCKET"),
        control_token: token,
        secrets: [token | Map.values(Map.take(env, ["OPENAI_API_KEY"]))],
        harness: [
          cwd: System.fetch_env!("WORKSPACE_CWD"),
          acp_path: System.fetch_env!("WORKSPACE_ACP_PATH"),
          env: env,
          env_file: System.fetch_env!("WORKSPACE_PROVIDER_ENV_FILE"),
          lease_file: System.fetch_env!("WORKSPACE_LEASE_FILE"),
          provider_session_file: System.fetch_env!("WORKSPACE_PROVIDER_SESSION_FILE")
        ]
      ]
end
