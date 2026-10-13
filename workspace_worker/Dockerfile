# Build from the repository root: docker build -f workspace_worker/Dockerfile .
# Official Elixir 1.19.6 / OTP 28 multi-platform image, verified October 12, 2026.
FROM elixir:1.19.6-otp-28@sha256:ead2215da1c6756a4cef5526e55a967e355c345ab3c6c03722618143bc9faa6a AS build

RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /build/workspace_worker
ENV MIX_ENV=prod
COPY priv/workspace_protocol/v1 /build/priv/workspace_protocol/v1
COPY workspace_worker/mix.exs workspace_worker/mix.lock ./
COPY workspace_worker/config ./config
RUN mix deps.get --only prod && mix deps.compile
COPY workspace_worker/lib ./lib
RUN mix compile --warnings-as-errors && mix release

# The build and runtime use the same libc and native process helper.
FROM elixir:1.19.6-otp-28@sha256:ead2215da1c6756a4cef5526e55a967e355c345ab3c6c03722618143bc9faa6a
WORKDIR /opt/workspace_worker
COPY --from=build /build/workspace_worker/_build/prod/rel/workspace_worker ./
RUN apt-get update && apt-get install -y --no-install-recommends git nodejs npm sudo python3 ca-certificates && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --shell /bin/bash --uid 10001 hermitworker \
    && useradd --create-home --shell /bin/bash --uid 10002 hermitcoder \
    && useradd --create-home --shell /bin/bash --uid 10003 hermitapp \
    && usermod --append --groups hermitapp hermitcoder
RUN npm install --prefix /opt/hermitscale/provider @openai/codex@0.162.1 @agentclientprotocol/codex-acp@1.6.2
COPY priv/workspace_launchers/sandbox-launch.py /opt/hermitscale/bin/sandbox-launch
COPY priv/workspace_launchers/docker-provider.py /opt/hermitscale/bin/codex-acp
RUN install -m 0755 /usr/bin/node /opt/hermitscale/bin/node \
    && printf '%s\n' 'Private management API is unavailable to this execution identity.' > /opt/hermitscale/blocked-api \
    && chown -R root:root /opt/workspace_worker /opt/hermitscale \
    && chmod -R go-w /opt/workspace_worker /opt/hermitscale \
    && chmod 0755 /opt/hermitscale /opt/hermitscale/bin /opt/hermitscale/bin/sandbox-launch /opt/hermitscale/bin/codex-acp \
    && chmod 0444 /opt/hermitscale/blocked-api \
    && printf '%s\n' 'hermitworker ALL=(root) NOPASSWD: NOSETENV: /opt/hermitscale/bin/sandbox-launch provider, /opt/hermitscale/bin/sandbox-launch provider *, /opt/hermitscale/bin/sandbox-launch signal *' > /etc/sudoers.d/hermitscale-coder \
    && chown root:root /etc/sudoers.d/hermitscale-coder \
    && chmod 0440 /etc/sudoers.d/hermitscale-coder \
    && visudo -cf /etc/sudoers.d/hermitscale-coder \
    && install -d -m 0700 -o hermitworker -g hermitworker /var/lib/hermitscale/control /var/lib/hermitscale/control/groups /var/lib/hermitscale/control/release-tmp /run/hermitscale /home/hermitworker \
    && install -d -m 0755 -o hermitcoder -g hermitcoder /workspace \
    && install -d -m 0700 -o hermitcoder -g hermitcoder /workspace/.codex /home/hermitcoder \
    && install -d -m 0700 -o hermitapp -g hermitapp /home/hermitapp \
    && install -d -m 2770 -o hermitapp -g hermitapp /workspace/data
USER hermitworker
ENV HOME=/home/hermitworker \
    SHELL=/bin/bash \
    PATH=/opt/hermitscale/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    RELEASE_TMP=/var/lib/hermitscale/control/release-tmp \
    WORKSPACE_WORKER_ENABLED=false \
    WORKSPACE_CWD=/workspace \
    WORKSPACE_ACP_PATH=/opt/hermitscale/bin/codex-acp \
    WORKSPACE_JOURNAL_PATH=/var/lib/hermitscale/control/journal.ndjson \
    WORKSPACE_CONTROL_SOCKET=/run/hermitscale/worker.sock \
    WORKSPACE_CONTROL_TOKEN_FILE=/var/lib/hermitscale/control/token \
    WORKSPACE_PROVIDER_ENV_FILE=/var/lib/hermitscale/control/provider-env.json \
    WORKSPACE_LEASE_FILE=/var/lib/hermitscale/control/lease.json \
    WORKSPACE_PROVIDER_SESSION_FILE=/var/lib/hermitscale/control/provider-session
WORKDIR /workspace
ENTRYPOINT ["/opt/workspace_worker/bin/workspace_worker"]
CMD ["start"]
