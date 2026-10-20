# Source-first Oh-My-Jido docs studio

A Phoenix application whose agent edits actual Markdown and application source. Native Oh-My-Jido sessions own the model/tool loop; SQLite holds run/event/candidate history, not page bodies. Published content comes from reviewed immutable files.

The application has two deliberately different roles:

| Role | Required authority and state |
| --- | --- |
| Trusted editor | Source checkout, local Git/Elixir/Mix toolchain, private SQLite/session/candidate storage, explicit operator password hash; explicit model account/key for inference |
| Public renderer | Built release and `SECRET_KEY_BASE`; packaged `priv/docs`, no studio database, agent Runtime, compiler, provider key or deployment token |

Production defaults to the public renderer. `DOCS_PREVIEW=1` always forces public-only mode. `DOCS_EDITOR_ENABLED=1` explicitly enables the private editor; do not expose it as an anonymous public service.

## Start the editor

Use Elixir1.20/OTP28 and Linux. The private candidate process backend requires `/proc`, `setsid`, `kill`, Python3 with working `os.pidfd_open`/`signal.pidfd_send_signal`, Git and a working native compiler toolchain. Its packaged Python helper verifies Linux child-subreaper support before dispatch; missing capabilities fail closed. The public renderer needs none of these editor helpers. This is a separate Mix project using the repository's licensed SDK snapshots and its own lockfile/build/dependencies.

```bash
cd examples/docs_site
export DOCS_CANDIDATE_PYTHON="${DOCS_CANDIDATE_PYTHON:-python3}"
"$DOCS_CANDIDATE_PYTHON" -I -B -S -c 'import os, signal; assert hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"), "select a Python build with Linux pidfd bindings"'
mix setup

read -rsp 'Editor password: ' DOCS_OPERATOR_PASSWORD
printf '\n'
export DOCS_OPERATOR_PASSWORD
export DOCS_OPERATOR_PASSWORD_HASH="$(mix run --no-compile --no-start -e 'IO.write(Pbkdf2.hash_pwd_salt(System.fetch_env!("DOCS_OPERATOR_PASSWORD")))')"
unset DOCS_OPERATOR_PASSWORD
export DOCS_OPERATOR_USERNAME=editor

mix phx.server
```

Some Python builds omit those bindings even on a capable Linux kernel. Select a capable interpreter explicitly (for example, `DOCS_CANDIDATE_PYTHON=/usr/bin/python3` where available); no interpreter, syscall shim or helper is downloaded automatically. The keeper independently verifies actual kernel capabilities before dispatch.

Visit `http://localhost:4000`, then follow the Studio login link. Phoenix also supports `iex -S mix phx.server`; the public docs path is ordinary server-rendered HTML.

There is no default password or registration. Production editor mode requires an explicit password hash. Signed sessions expire and password-hash rotation invalidates old authorization; production cookies are secure. Development HTTP cookies are not secure.

The application does not automatically load `.env` files or discover provider credentials. To run inference, set `DOCS_MODEL` to a currently active provider-qualified model supported by your installed catalog and `DOCS_MODEL_API_KEY` to its explicitly authorized key **before starting the editor**. Catalog recognition alone does not establish current provider availability or authorize billing. Native scripted providers are host-only test fixtures and are disabled in normal application startup.

## Operate the source loop

1. Start a **docs** run to edit only `priv/docs`, or deliberately choose **coding** for application source and approved Shell access.
2. Follow durable native events, answer clarification/approval questions, steer or cancel. Every subprocess—including Git/ripgrep—requires a fresh approval. Browser disconnect does not stop work.
3. Prepare a candidate and inspect its immutable diff and digest.
4. Start checks. These use copied dependencies and private build/home directories; no child `deps.get`, asset installer or provider/deployment credentials are inherited. Missing tools are a real unavailable capability, not a passing check.
5. Open the actual separately built Phoenix release preview. The protected proxy uses a sandboxed frame and never forwards editor cookies.
6. Approve the **exact** successful candidate digest. Later source changes invalidate stale authority.
7. Publish docs or adopt code. Documentation publication first adopts reviewed Markdown into canonical source, so the next agent run starts from the published text; then it changes the local publication pointer. A partial failure retains its adoption/uncertainty receipt, never rolls back or silently replays an effect.
8. Deploy only after explicitly configuring and approving the Fly target. Local publication is not an external Fly deployment.

A model's final paragraph is not verification: a completed turn can contain a
failed tool. Native Action deadlines also bound pending process approval. If a
decision expires, inspect/reconcile the actual receipt before authorizing any new
effect; never infer execution from model prose or retry to discover the outcome.

Adoption never overwrites the configured seed checkout or reloads editor modules. It creates a durable local Git source under `DOCS_DATA_DIR` and atomically switches the authoritative source pointer; future runs use that source. Unrelated initial checkout changes are preserved when they do not conflict with reviewed paths. If adopted bytes differ from the checked candidate, deployment requires a new review. Automatic host code reloading and asset watchers are disabled; only a separate built preview or explicitly deployed application activates the new code.

### Toolchain configuration

`mix setup` installs the native Esbuild/Tailwind tools in this application's cache. At editor startup, their SDK-provided binary paths and Mix's installed Rebar path are captured once for child builds; tools are never installed by a candidate. Explicit `ESBUILD_PATH`, `TAILWIND_PATH` and `DOCS_MIX_REBAR3` override those cached paths. A release-hosted private editor must supply its own external source/toolchain; the public image intentionally does not include it.

`DOCS_CANDIDATE_PYTHON` selects the private editor's Python executable (default `python3`, application setting `:candidate_python_executable`). The trusted packaged keeper runs with `-I -B -S`; it never imports authored source. It retains orphaned descendants until kernel reaping proves closure. Missing receipts or abnormal keeper loss block later effects; partial bounded process history still fails checks even when physical cleanup is proven. This is not a hostile same-user sandbox or a kernel resource quota.

The explicit `DOCS_CANDIDATE_PYTHON` selection is retained in project-check children, including tests that launch nested keepers. It is an approved toolchain setting, not an ambient provider credential or an automatic interpreter fallback.

Each command retains at most1,024 observed OS identities; keeper status and durable lease files are bounded to512KiB. Version2 keeper status separates the complete historical inventory from the current live inventory, so exited processes are not repeatedly read under the live-refresh deadline. Overflow, incomplete observation or missing proof still fails the check even when kernel reaping independently confirms physical cleanup.

Settle all candidate work with the matching editor before upgrading from private keeper version1. Version1 status/locators are not silently upgraded or accepted by the version2 controller; use the compatible prior editor to reconcile any active old lease. The separately bound dispatch acknowledgement remains version1. These are private example-process protocols, not changes to library session checkpoints.

Compile/install approved native dependencies once during trusted setup before requesting offline candidate checks. The editor copies checksum-validated artifacts into private caches; it does not download them during checks. `DOCS_RUSTLER_CACHE` selects the flat tarball directory (normally the native user cache's `rustler_precompiled/precompiled_nifs`), and `DOCS_ELIXIR_MAKE_CACHE` selects the native `elixir_make` cache. Missing artifacts fail preflight/checks. Downloaders' explicit loopback-dead proxy settings prevent their ordinary fallback fetches; this does not prevent deliberately authored child code from using the network.

Offline Git caches preserve the actual locked origin and revision, not just source bytes. Only identity metadata is retained; hooks, includes and credential helpers are stripped. Remote URL userinfo is rejected except for a password-free SSH username; configure authentication outside the URL.

`DOCS_SOURCE_ROOT` selects the initial trusted repository seed, not just this example. `DOCS_DATA_DIR` holds private durable history and managed source versions, defaulting to `var/` in development. `Workspaces.current_source/0` returns the actual authoritative source root/digest after adoption. The immutable managed source must not be edited in place; make further changes through a new run/review. `DATABASE_PATH` optionally selects the studio SQLite file. Existing tracked dirty seed bytes are included initially; untracked source requires trusted `:approved_source_paths`, never model self-approval.

Namespace folders such as `lib/runtime/`, `lib/cache/` and `docs/runtime/` remain authored source. Operational root `runtime/` and `cache/` remain private; `.runtime`, `.cache`, secret files and database files are excluded everywhere, including when Git tracks them.

Only one editor BEAM may own a given source checkout/data directory. The reference application does not provide multi-editor replication or cross-VM filesystem publication locks.

The global candidate effect limit is one: stop an existing preview before another check or deployment. Checks have a10-minute total deadline; preview readiness30seconds and lifetime15minutes; deployment15minutes. The UI retains actual cancellation/uncertainty receipts rather than treating a killed local client as proof that an external effect stopped.

## Deployment

From the repository root, build the real public-only image:

```bash
docker build -f examples/docs_site/Dockerfile -t oh-my-jido-docs .
```

The builder uses the inspected official [Elixir1.20.2/OTP28 image](https://hub.docker.com/v2/repositories/library/elixir/tags/1.20.2-otp-28), pinned by its multi-platform index digest. Runtime contains the release and native runtime libraries, not Git/Mix/compiler/source caches. Secrets are runtime inputs, never build arguments. Review the root `.dockerignore` before adding source paths.

The root `.dockerignore` excludes known credential paths, private-key/container extensions and conventional private PEM names, SQLite/database files and private operational roots. Its `runtime`/`cache`/`caches` rules apply only to repository, example and vendored-package roots; authored namespaces under `lib`, `src`, `include`, `test`, `tests`, `assets` and `docs` remain source. Public certificate/public-key PEM source remains allowed. Unlike candidate source copying, Docker ignore rules cannot inspect PEM boundaries or detect arbitrary embedded secrets.

Keep custom `DOCS_DATA_DIR`, `DATABASE_PATH`, `DOCS_PUBLISHED_ROOT`, backup and credential locations outside the entire repository-root Docker build context, or add explicit reviewed exclusions for every custom path before building. This applies even to private paths nested under `priv`, `vendor` or the example: `COPY` and release packaging do not make them private.

`fly.toml` targets one shared CPU and512MB with automatic stop/start and an HTTP docs health check carrying `X-Forwarded-Proto: https`, so the production HTTPS plug handles the internal probe without a redirect. HTTPS enforcement and the public-only endpoint/auth policy are unchanged. Public Fly needs no persistent volume. These are configuration choices, not an unmeasured capacity guarantee; current exercised resource/release evidence belongs in the repository's [progress ledger](../../docs/oh-my-jido/PROGRESS.md).

Reserve the app and install its `SECRET_KEY_BASE` only after approving the external effects. Set `PHX_HOST` to the actual public hostname. The editor deployment action additionally requires all of `DOCS_FLYCTL` (absolute executable), `DOCS_FLY_APP` and private `DOCS_FLY_TOKEN`; it never discovers a login/token or implicitly creates an app. It builds/deploys the reviewed repository-root context with `examples/docs_site/Dockerfile` and `examples/docs_site/fly.toml`. The token is child-private and output is bounded/redacted.

For a local release rather than Docker:

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.setup
MIX_ENV=prod mix compile --warnings-as-errors
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
export SECRET_KEY_BASE="$(openssl rand -hex 64)"
PHX_SERVER=true DOCS_EDITOR_ENABLED=0 RELEASE_DISTRIBUTION=none PORT=4001 _build/prod/rel/oh_my_jido_docs/bin/oh_my_jido_docs start
```

Do not run a private editor release with default development paths: set absolute `DOCS_SOURCE_ROOT`, `DOCS_DATA_DIR`, a password hash and the explicit toolchain/configuration first.

## Recovery without effect replay

Observer restart rejoins surviving writer holders. A terminal run releases its
workspace fence only after native `stop_session/1` confirms settlement and the exact
session actor exits. Holder death or whole-runtime loss leaves a durable
`source_writer_pending` claim; it does not authorize publication.

If graceful settlement cannot be recovered, a trusted operator must first confirm
the old native actor is absent and independently inspect/stop its actual owned OS
resources. Only then, in the **private editor's own trusted IEx session**:

```elixir
alias OhMyJidoDocs.Editor
run = Editor.get_run!(run_id)
Editor.reconcile_writer(run.id, run.source_writer_token, :orphan_resources_reconciled)
```

The exact claim token prevents stale acknowledgement from clearing a later writer.
The receipt records `operator_reconciled: true`, not fictitious native cleanup.
This API is deliberately absent from agent tools and public routes. Explicit
`Editor.resume_run(run.id)` restores context; a later explicit steer starts a new
turn, never a replay of the interrupted effect.

Candidate checks, previews and deployment use one durable process lease under
`candidate-effects/active-process-lease.json`. Every child reserves its launch
generation before spawning. Identity-confirmed cleanup is retained in
`process-lease-receipt.json`; an earlier step's receipt cannot release a newer child.
After interruption, `OhMyJidoDocs.Candidates.reconcile_process_cleanup/0` stops
dedicated orphan tasks and retries identity-safe cleanup. Missing/mismatched proof
stays blocked across restart. Preserve the receipt and investigate independently;
do not delete the lease or retry deployment to guess what happened. Confirmed local
cleanup does not establish an external Fly outcome.

## Durability and backup

The private editor uses SQLite WAL with one connection and a busy timeout. Native checkpoints, source workspaces, immutable candidates, canonical adopted Git source versions/pointer, publication snapshots and effect receipts live under private `DOCS_DATA_DIR`. `DOCS_SOURCE_ROOT` remains the original seed checkout. Neither store is encrypted by this example.

Startup creates/restricts `DOCS_DATA_DIR` to0700 before publication/session state is written. Start setup with `umask 077`. If `DATABASE_PATH` or `DOCS_PUBLISHED_ROOT` points outside this private root, the operator must protect those external parent directories/files separately; the application does not chmod arbitrary external parents.

For a consistent cold backup: finish/cancel work and stop previews; stop the editor; archive its complete data directory (including SQLite/WAL files, managed Git source versions and pointers), any external database/publication overrides, and the seed checkout you intend to retain into operator-owned encrypted storage outside served/agent/build paths. Preserve permissions and stable absolute paths. Back up credentials through your own vault, not event exports. Restore while stopped, verify ownership/paths, then start the same compatible application/SDK version. Recovery restores identities and marks interrupted/uncertain effects; it never automatically reruns a model turn, command, publication or deployment. Reconcile actual source/external state before explicitly continuing.

The public image is disposable: redeploy the reviewed source release. It has no studio volume to back up and no replication/failover claim.

## Exercised local acceptance

- [Complete editorial loop](../../docs/oh-my-jido/evidence/editorial-complete-20261020.json): actual native tools, immutable checks/release/preview, real source-drift refusal, digest approval, local publication/adoption and a fresh native Read from adopted Git source.
- [Capped public release](../../docs/oh-my-jido/evidence/docs-site-production-capped-20261020.json): enforced512MiB/no-swap process scope, real public/private routes, scriptless desktop/mobile and the exact configured HTTPS health-probe headers. This is not a whole-Fly-VM capacity or external deployment claim.
- [Complete cold restore](../../docs/oh-my-jido/evidence/docs-site-cold-restore-20261020.json): full stopped data archive, actual extraction into an absent original path, byte/metadata comparison, exact native/candidate/source equality and authenticated reconnect. Disposable local archives do not replace operator-owned encrypted production backup/vault procedures.
- [Docker context boundary](../../docs/oh-my-jido/evidence/dockerignore-boundary-20261020.json):44 official Moby parser/matcher cases, not an image-build or arbitrary embedded-secret scanner claim.

## Security boundary

This is a trusted-editor reference application, **not an OS sandbox**. Private environment/cwd/home/build paths and process-group cleanup prevent accidental inheritance and cross-run cache mutation; deliberately authored child code can still access the editor OS user's files/network or escape process sessions. Do not approve hostile code or grant untrusted users editorial execution authority. Whole-host failure or escaped descendants can leave effects uncertain; restart reconciliation records uncertainty rather than claiming perfect containment or retrying effects. Use an external OS/user/container isolation policy if your threat model requires it.

Markdown is parsed by pinned MDEx with unsafe HTML disabled and its native sanitizer enabled. Content is never compiled as HEEx. Inventories allow at most128 pages,256KiB per page,4MiB total content,1,024 total file/directory entries and directory depth8. Oversized directory listings are rejected before sorting/descent; file reads are bounded even if files grow after stat. Symlinks, traversal, unsupported entries and modified immutable snapshots fail closed. Auth protects runs, questions, diffs, candidate controls and preview proxy access.

## Checks and versions

```bash
mix ci
```

This runs warnings-as-errors compilation, formatting, behavior tests, strict Credo/ExSlop, Dialyzer, zero-clone ExDNA and Reach architecture/smell checks. Candidate builds exclude only the recursive `candidate_integration` lifecycle tests, not the parent acceptance suite. Root library `mix ci` remains a separate required gate. Do not replace the full native agent loop with fake forwarding tests or claim an external deployment from a local release.

`master` uses the audited stable Jido2.4 stack. The `jido-v3-preview` branch carries the same substantive application against an actual coherent native V3 SDK pair; its SDK `UPSTREAM` records and progress ledger identify exact revisions and honest upstream metadata. Worktrees must use independent Mix dependencies/builds. Switching only a package version label is not a V3 port.

Phoenix references: [deployment](https://phoenix.hexdocs.pm/deployment.html), [guides](https://phoenix.hexdocs.pm/overview.html), [source](https://github.com/phoenixframework/phoenix).
