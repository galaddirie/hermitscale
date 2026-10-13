# Private Sprite workspace worker

The worker runs Jido Harness ACP beside a retained checkout. `Hermitscale.Workspaces.Setup` installs the worker release and pinned Codex/ACP provider once, initializes ordinary Git source, and registers the native `hs-worker` service as `hermitworker`. The provider runs as `hermitcoder`; app services run as `hermitapp`.

The host reaches `/run/hermitscale/worker.sock` through authenticated Sprite exec and length-prefixed JSON. The private transport credential stays in protected worker files. Only the selected OpenAI API key reaches the provider. Its environment replaces inherited variables; Sprite management credentials and Git credentials remain separate. The root-owned launcher masks the management socket, drops capabilities and changes identity before running repository code.

The worker fsyncs each admitted command before acceptance. Operation identity, payload digest, generation and deadline bind reconnects, permission responses, cancellation and event reads. Reconnection inspects accepted work rather than starting another model turn. Provider history is retained through Harness continuation. Restart marks unfinished work uncertain and reconciles recorded process groups before admitting another writer.

Completion, cancellation and expiry close Harness and verify process termination. A bounded native Sprite task hold keeps the admitted turn awake. The host independently verifies recorded groups and remaining coder processes before releasing its lease. Authority revocation can stop an already admitted writer while retaining its files.

Provider starts clear the previous `.hermitscale/result.json`. Requested structured output reads only that bounded file; ordinary conversations use provider events. No repository walk or mandatory evidence export runs at completion.

The release reads `WORKSPACE_ID`, `WORKSPACE_CWD`, `WORKSPACE_JOURNAL_PATH`, `WORKSPACE_ACP_PATH`, `WORKSPACE_CONTROL_SOCKET`, `WORKSPACE_CONTROL_TOKEN_FILE`, `WORKSPACE_PROVIDER_ENV_FILE`, `WORKSPACE_LEASE_FILE` and `WORKSPACE_PROVIDER_SESSION_FILE`. `WORKSPACE_WORKER_ENABLED=true` starts the service. Provider JSON permits `OPENAI_API_KEY`, `PATH`, `HOME` and `CODEX_HOME` only.

Run `MIX_ENV=core mix test` for local protocol, journal, control and runtime tests. The full Harness release requires Linux native build tools and Elixir 1.19. Run `python3 -m unittest discover -s priv/workspace_launchers` from the repository root for launcher and ordinary Git tests.

An optional Docker package builds from the repository root with `docker build -f workspace_worker/Dockerfile .`. It requires the Sprite management socket and mount namespace support at runtime. The host normally installs the release directly on a Sprite. Keep worker control files private and retain the checkout and provider history between starts.
