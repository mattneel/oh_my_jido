# Run the docs studio

This Phoenix application shows how to embed Oh-My-Jido in a working product. A coding agent edits Markdown or application source in a separate workspace. You review the diff, run checks, open a built preview, and approve the exact source you want to publish. SQLite stores runs, events and review history; page bodies stay in files.

Oh-My-Jido is an Elixir library for adding a coding agent to your own application. Jido manages agents and their OTP lifecycle, Jido.AI runs the model/tool loop, and ReqLLM connects to model providers. The studio supplies the workspace, credentials, permissions and human controls around that library.

## Choose the app's role

| Role | What it does | What it needs |
|---|---|---|
| Trusted editor | Runs agents, edits source, checks candidates and controls publication/deployment. | A trusted source checkout, Git/Elixir/Mix and native build tools, private SQLite/session/candidate storage, an operator password hash, and an explicitly configured model/key for AI tasks. |
| Public renderer | Serves the documentation packaged in a built release. | The release and a production `SECRET_KEY_BASE`. It starts no studio database or agent runtime and needs no model key, deployment token, compiler or source checkout. |

Development enables the editor by default; production disables it. Set `DOCS_EDITOR_ENABLED=1` to opt in explicitly. `DOCS_PREVIEW=1` always forces public-only mode, even if the editor flag is set. Keep editorial access private; it authorizes real source execution, not anonymous document submissions.

## Start the editor

Use Linux with Elixir 1.20 and OTP 28. The editor needs Git, ripgrep (`rg`), a native compiler toolchain, `/proc` and the Linux process utilities used by the library (`setsid`, `sh`, `mkfifo`, `cat`, `kill`). Candidate checks also need Python 3 with working `os.pidfd_open`, `signal.pidfd_send_signal` and Linux child-subreaper support. The public renderer does not need these editor helpers.

This example is a separate Mix project. Run its setup from `examples/docs_site`; it uses the repository's licensed SDK snapshots and its own lockfile, dependencies and build directory.

From the repository root, run these commands in Bash:

```bash
cd examples/docs_site
umask 077
export DOCS_EDITOR_ENABLED=1
export DOCS_CANDIDATE_PYTHON="${DOCS_CANDIDATE_PYTHON:-python3}"
"$DOCS_CANDIDATE_PYTHON" -I -B -S -c 'import os, signal; assert hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"), "select a Python build with Linux pidfd bindings"'
mix setup

read -rsp 'Editor password: ' DOCS_OPERATOR_PASSWORD
printf '\n'
export DOCS_OPERATOR_PASSWORD
export DOCS_OPERATOR_PASSWORD_HASH="$(mix run --no-compile --no-start -e 'IO.write(Pbkdf2.hash_pwd_salt(System.fetch_env!("DOCS_OPERATOR_PASSWORD")))')"
unset DOCS_OPERATOR_PASSWORD
export DOCS_OPERATOR_USERNAME=editor

# Choose a currently active model and an account authorized to pay for it.
export DOCS_MODEL=anthropic:claude-sonnet-4-6
read -rsp 'Model API key: ' DOCS_MODEL_API_KEY
printf '\n'
export DOCS_MODEL_API_KEY

mix phx.server
```

Open `http://localhost:4000`, follow the Studio link and sign in. You can use `iex -S mix phx.server` instead when you need a trusted recovery console. The public documentation uses ordinary server-rendered HTML.

There is no default password or registration. Signed operator sessions last eight hours. Rotating the username/password hash invalidates old authorization. Production cookies are secure; development HTTP cookies are not.

The application does not load `.env` files or discover provider credentials. Configure `DOCS_MODEL` and `DOCS_MODEL_API_KEY` before startup. You can serve docs and sign in without a model key, but cannot submit AI tasks. A model being recognized by the installed catalog does not prove the provider still offers it or authorize billing. Scripted model providers are trusted test fixtures, disabled in normal startup.

Some Python builds omit the pidfd bindings even on a capable kernel. If necessary, select a capable interpreter such as `/usr/bin/python3` with `DOCS_CANDIDATE_PYTHON`. Nothing downloads an interpreter, syscall shim or process helper. The packaged helper checks actual kernel support before dispatch and refuses to launch when required capabilities are missing.

## Operate the source loop

1. Choose a run mode, enter a task and start work.
2. Follow the saved events. Answer clarification and approval questions, steer the agent, or cancel/suspend the run. Every agent-launched subprocess, including Git and ripgrep, requires a fresh approval. Closing the browser does not stop work.
3. Prepare a candidate. A candidate is an immutable copy of exact source bytes, identified by a digest. Read its diff before continuing.
4. Start checks. The child pipeline compiles dependencies and the app, runs tests, builds assets and creates a production release. Missing tools or caches make checks unavailable or failed, never successful by assumption.
5. Open the separately built Phoenix release preview. The protected proxy displays it in a sandboxed frame and never forwards editor cookies.
6. Approve the exact successfully checked candidate digest. Later source changes invalidate the old authority.
7. Publish documentation or adopt code. Publishing first adopts the reviewed Markdown as the source for future runs, then switches the local public-content pointer. A partial failure keeps its adoption/uncertainty receipt; it does not roll back or silently replay an effect.
8. Deploy only after separately configuring and approving the Fly target. Local publication does not deploy the public Fly app.

| Run mode | Tools and permissions | Allowed changes |
|---|---|---|
| `docs` (default) | Read, Search, List, Write, Edit, read-only Git operations and Question; permissions `[:read, :edit, :git, :ask]`. | Writes only under `priv/docs`. No Shell. |
| `coding` | The same tools plus Shell and `:exec` permission. | Application source in the copied workspace. Execution still needs per-process approval. |

A completed model turn can contain a failed tool call. Inspect tool/check receipts, not the model's final paragraph, to determine what happened. Tool deadlines also bound pending process approval. If an approval expires, inspect and reconcile the receipt before authorizing another effect; do not retry to discover whether the first one ran.

### Where adopted source goes

Adoption does not overwrite the seed checkout or reload modules in the editor VM. It creates a durable local Git source version under `DOCS_DATA_DIR` and atomically changes the authoritative source pointer. Future runs use that source; `OhMyJidoDocs.Workspaces.current_source/0` reports its root and digest. Do not edit an immutable managed source version in place. Make further changes through another run and review.

Tracked dirty seed files are included in the initial snapshot. Untracked source needs the trusted application setting `:approved_source_paths`; the model cannot approve it. Unrelated changes in the seed checkout are preserved when they do not conflict with reviewed paths. If adoption produces bytes different from the checked candidate, deployment needs a new review.

Source selection preserves authored namespaces such as `lib/runtime/`, `lib/cache/` and `docs/runtime/`. Operational root `runtime/` and `cache/` stay private. `.runtime`, `.cache`, secret files and database files are excluded everywhere, even when Git tracks them.

Code reloading and asset watchers are disabled. New code runs only in a separately built preview or an explicitly deployed application. Only one editor BEAM may own a source checkout/data directory; there is no multi-editor replication or cross-VM filesystem publication lock.

### Prepare an offline build toolchain

`mix setup` installs native Esbuild and Tailwind tools in this app's cache. At editor startup, the app captures their binary paths and Mix's installed Rebar path for child builds. `ESBUILD_PATH`, `TAILWIND_PATH` and `DOCS_MIX_REBAR3` override those paths. A candidate never runs `deps.get` or an asset installer, and receives no ambient provider/deployment credentials. A release-hosted editor must have an external trusted source checkout and toolchain; the public image intentionally omits them.

Compile/install approved native dependencies during trusted setup. Checks copy checksum-validated native artifacts into private caches instead of downloading them. `DOCS_RUSTLER_CACHE` selects the flat tarball directory; `DOCS_ELIXIR_MAKE_CACHE` selects the native `elixir_make` cache. Missing artifacts fail preflight/checks. Offline/proxy settings block the downloaders' ordinary fallback fetches, not network access by deliberately authored code.

Offline Git caches retain the actual locked origin and revision. Only identity metadata is copied; hooks, includes and credential helpers are stripped. URLs containing userinfo are rejected except for a password-free SSH username. Configure authentication outside the URL.

The trusted Python process helper runs with `-I -B -S` and never imports authored source. It acts as a child subreaper, retaining orphaned descendants until kernel reaping proves cleanup. The selected `DOCS_CANDIDATE_PYTHON` is also passed to check children that launch nested helpers. Missing receipts or abnormal helper loss block later effects. Incomplete process history still fails checks even if physical cleanup is proven.

### Execution limits

| Limit | Default/contract |
|---|---|
| Concurrent candidate effects | One across checks, previews and deployment. Stop the current preview before another check/deployment. |
| Check deadline | 10 minutes for the whole pipeline. |
| Preview readiness / lifetime | 30 seconds / 15 minutes. |
| Deployment deadline | 15 minutes. Killing the local client does not prove an external deployment stopped. |
| Per-command observed OS identities | 1,024. Overflow or incomplete observation fails the check. |
| Process-helper status / durable lease size | 512 KiB each. Missing or oversized proof is not accepted. |
| Editor runtime | 8 sessions, 1 active model run, 1 process slot, 1 subagent slot, 8 resources; 64 runs and 256 effects per session; a 256-event buffer. |

The private helper's version-2 status keeps historical and currently live process inventories separate, so exited processes do not consume the live-refresh deadline. Settle all candidate work with the matching editor before upgrading from helper version 1. A version-2 controller does not silently upgrade or accept version-1 status/locators; reconcile an old active lease with the compatible prior editor. The separately bound dispatch acknowledgement remains version 1. These private process protocols are unrelated to library session checkpoint versions.

## Configuration reference

These defaults describe normal development/production startup. Test configuration overrides its data/publication/database paths. Set environment variables before starting the app; it does not watch them for changes.

### Role, content and storage

| Variable | Default | Meaning |
|---|---|---|
| `DOCS_EDITOR_ENABLED` | `1` outside production; `0` in production | Only `1` enables the trusted editor. |
| `DOCS_PREVIEW` | Unset | `1` forces public-only mode and a production loopback listener. |
| `DOCS_SOURCE_ROOT` | Repository root above this example | Initial trusted seed repository, not the current adopted source. Must be explicitly absolute for a production editor. |
| `DOCS_DATA_DIR` | `examples/docs_site/var` | Private durable state. Must be explicitly absolute for a production editor. Cannot be the filesystem root or contain the seed checkout. |
| `DATABASE_PATH` | `$DOCS_DATA_DIR/studio.db` | Editor SQLite database; ignored by the public renderer. |
| `DOCS_PUBLISHED_ROOT` | `$DOCS_DATA_DIR/published` | Editor publication snapshots and pointer. Not a way to change a public renderer's packaged docs. |
| `DOCS_STATIC_ROOT` | Packaged `priv/docs` | Trusted Markdown root for public-only rendering and initial editor bootstrap. Bootstrap happens only when no publication pointer exists. |

### Identity, inference and deployment

| Variable | Default | Meaning |
|---|---|---|
| `DOCS_OPERATOR_USERNAME` | `editor` | Single operator's login name. |
| `DOCS_OPERATOR_PASSWORD_HASH` | None | PBKDF2 hash beginning with `$pbkdf2-`. Required for production editor startup and any working login. |
| `DOCS_MODEL` | None | Explicit provider-qualified model for studio tasks, including on the preview branch. |
| `DOCS_MODEL_API_KEY` | None | Explicit key for the configured model. The account reference is the application setting `:model_account`, default `"docs-site"`, not an environment variable. |
| `DOCS_FLYCTL` | None | Absolute path to an installed Fly executable. |
| `DOCS_FLY_APP` | None | Already reserved Fly app name. |
| `DOCS_FLY_TOKEN` | None | Private token used only in an explicitly requested deployment child. All three Fly settings are required for the deployment action. |

`DOCS_OPERATOR_PASSWORD` in the quick start is a temporary input to the hash-generation command, not application configuration. Unset it after generating the hash. Never put passwords, model keys or Fly tokens into tasks, Markdown, event exports or source files.

### Editor toolchain

| Variable | Default | Meaning |
|---|---|---|
| `DOCS_CANDIDATE_PYTHON` | `python3` | Interpreter for the trusted Linux process helper; maps to `:candidate_python_executable`. |
| `ESBUILD_PATH` | Cached Esbuild binary | Explicit binary for asset tasks and candidate builds. Read by compile-time and runtime configuration. |
| `TAILWIND_PATH` | Cached Tailwind binary | Explicit binary for asset tasks and candidate builds. Read by compile-time and runtime configuration. |
| `DOCS_MIX_REBAR3` | Mix's installed Rebar path | Passed to child builds as `MIX_REBAR3`. |
| `DOCS_RUSTLER_CACHE` | `:filename.basedir(:user_cache, "rustler_precompiled/precompiled_nifs")` | Flat native tarball cache copied for offline checks. |
| `DOCS_ELIXIR_MAKE_CACHE` | `:filename.basedir(:user_cache, "elixir_make")` | Native `elixir_make` cache copied for offline checks. |
| `PATH` | Editor environment, otherwise `/usr/local/bin:/usr/bin:/bin` | Candidate executable search path, unless overridden by trusted `:candidate_path` configuration. |
| `MIX_HOME` | Editor environment, otherwise `~/.mix` | Source of installed Mix archives to copy, unless overridden by `:candidate_mix_home`. The child gets a private Mix home. |

Native compiler overrides `CC`, `CXX` and `MAKE` must be supplied through the trusted `:candidate_toolchain_env` application setting; merely exporting them does not add them to a candidate's environment. That setting accepts only those keys plus `MIX_REBAR3`, `ESBUILD_PATH` and `TAILWIND_PATH`.

### Server and release

| Variable | Default | Meaning |
|---|---|---|
| `SECRET_KEY_BASE` | Development/test config only | Required in production, at least 64 bytes. Also required by the public renderer. |
| `PHX_HOST` | `localhost` | Production public hostname; generated URLs use HTTPS on port 443. |
| `PHX_SERVER` | Unset | `true` or `1` enables the endpoint in a release. `mix phx.server` handles development startup. Docker/Fly set `true`. |
| `PORT` | `4000` | HTTP listener port. Docker/Fly use `8080`. |
| `MIX_ENV` | Mix's development default | Use `prod` to build a release; the candidate pipeline selects `test` and `prod` itself. |
| `RELEASE_DISTRIBUTION` | Release default outside the supplied setup | Docker/Fly and the local-release command set `none`; no distributed node is needed. |
| `ERL_AFLAGS` | Unset locally | Fly sets `+S 1:1 +A 2` for its public VM. |

Candidate children get a constructed environment, not a copy of the editor's environment. The following are internal child settings, not extra operator configuration:

| Child variables | Assigned behavior |
|---|---|
| `HOME`, `TMPDIR`, `MIX_HOME`, `HEX_HOME`, `MIX_DEPS_PATH`, `MIX_BUILD_PATH` | Private per-attempt paths; dependencies are copied, not shared for mutation. |
| `HEX_OFFLINE`, `CARGO_NET_OFFLINE`, `CARGO_HOME`, `RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH`, `ELIXIR_MAKE_CACHE_DIR` | Offline builds and private native caches. |
| `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and lowercase variants; `NO_PROXY` / `no_proxy` | Loopback-dead proxies with a loopback exclusion for checks; proxy settings are removed for deployment. |
| `GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_GLOBAL`, `GIT_CEILING_DIRECTORIES`, `GIT_ALLOW_PROTOCOL`, `GIT_ASKPASS`, `GIT_SSH_COMMAND`, `GIT_TERMINAL_PROMPT`, `GIT_OPTIONAL_LOCKS` | Disable ambient Git config, credential prompts, transports and optional locks in build children. |
| `ERL_FLAGS`, `LANG` | Candidate VM flags default to `+S 2:2 +SDcpu 1 +SDio 1`; locale is `C.UTF-8`. |
| `DOCS_CHILD`, `DOCS_DEPENDENCY_PATHS` | Child role marker and private dependency-preflight metadata path. |
| Preview server variables | Fresh `SECRET_KEY_BASE`, selected loopback `PORT`, `PHX_HOST=localhost`, `PHX_SERVER=true`, `DOCS_PREVIEW=1`, `DOCS_EDITOR_ENABLED=0`, private data/database roots and `RELEASE_DISTRIBUTION=none`. `POOL_SIZE=1` is also set; it is not an operator-facing database pool setting. |
| `FLY_API_TOKEN` | Set from `DOCS_FLY_TOKEN` only for deployment, with bounded/redacted output. |

## Deploy the public renderer

### Docker

Build from the repository root:

```bash
docker build -f examples/docs_site/Dockerfile -t oh-my-jido-docs .
export SECRET_KEY_BASE="$(openssl rand -hex 64)"
docker run --rm -p 8080:8080 --env SECRET_KEY_BASE --env PHX_HOST=localhost oh-my-jido-docs
```

The builder uses the official Elixir 1.20.2 / OTP 28 image pinned by its multi-platform index digest. The runtime image contains the release and native runtime libraries, not Git, Mix, compilers or source caches. Supply secrets at runtime, never as build arguments.

Review the repository-root `.dockerignore` before adding source paths. It excludes known credential locations, private-key/container extensions, conventional private PEM names, database files and private operational roots. Root `runtime`/`cache`/`caches` rules cover repository, example and vendored-package roots; authored namespaces under `lib`, `src`, `include`, `test`, `tests`, `assets` and `docs` remain source. Public certificate/public-key PEM files remain allowed. Unlike candidate source copying, Docker ignore rules cannot inspect PEM boundaries or find arbitrary embedded secrets.

Keep custom data, database, publication, backup and credential locations outside the entire repository-root build context, or add a reviewed exclusion for each path. This includes private files nested under `priv`, `vendor` or the example. `COPY` and release packaging do not make a file private.

### Fly

Reserve the app and install its `SECRET_KEY_BASE` only after approving those external changes. Set `PHX_HOST` to its real public hostname. The supplied `fly.toml` configures one shared CPU, `512mb` memory, automatic stop/start and a `/docs/index` health check. Its `X-Forwarded-Proto: https` header lets the internal HTTP probe pass the production HTTPS plug without a redirect; public HTTPS enforcement stays enabled. The public app needs no persistent volume. These settings are not a capacity guarantee.

For deployment from Studio, configure all three `DOCS_FLYCTL`, `DOCS_FLY_APP` and `DOCS_FLY_TOKEN` settings, then approve the exact checked candidate and request deployment. The action uses the reviewed repository-root context with `examples/docs_site/Dockerfile` and `examples/docs_site/fly.toml`. It neither discovers an existing login/token nor creates an app. The token is private to the deployment child; its output is bounded and redacted.

### Local release

Run from `examples/docs_site`:

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.setup
MIX_ENV=prod mix compile --warnings-as-errors
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
export SECRET_KEY_BASE="$(openssl rand -hex 64)"
PHX_SERVER=true DOCS_EDITOR_ENABLED=0 RELEASE_DISTRIBUTION=none PORT=4001 _build/prod/rel/oh_my_jido_docs/bin/oh_my_jido_docs start
```

To run a private editor release instead, first supply absolute `DOCS_SOURCE_ROOT` and `DOCS_DATA_DIR`, a password hash, and the external toolchain/configuration. Do not rely on development paths inside a release.

## Recover without replay

The background Observer saves native events independently of browser connections. After its restart it rejoins surviving writer holders. A writer holder keeps a workspace fenced against publication for the full agent lifetime. A terminal run releases that fence only after `OhMyJido.stop_session/1` confirms settlement and the exact session actor exits. Holder death or loss of the whole runtime leaves `source_writer_pending`; it is not permission to publish.

Queued cancellation also waits for its workspace creator and actual allocation cleanup. Pending cleanup continues to count against admission until deletion succeeds. Recovery joins surviving tasks rather than assuming their allocations disappeared.

### Reconcile an orphaned source writer

If graceful settlement cannot be recovered, independently confirm that the old native actor is absent and inspect/stop its actual owned OS groups and external resources. Process death alone does not prove cleanup. Only after that work, use the private editor's trusted IEx session:

```elixir
alias OhMyJidoDocs.Editor
run = Editor.get_run!(run_id)
Editor.reconcile_writer(run.id, run.source_writer_token, :orphan_resources_reconciled)
```

The operation checks the exact durable writer claim and old-owner absence. It holds the workspace lease, persists private operator provenance before starting a temporary restored owner, imports the operator's execution settlement and obtains a confirmed stop for that new owner before releasing the fence. It preserves uncertain outcomes without inventing results or completion times.

| Receipt field | Meaning |
|---|---|
| `operator_reconciled: true` | The operator independently reconciled the original resources. |
| `native_stop_confirmed: false` | No native cleanup receipt is claimed for the lost original owner. |
| `restored_owner_stop_confirmed: true` | The temporary restored owner was actually stopped. |

The exact claim token prevents a stale acknowledgement from clearing a later writer. Recovery gets the interrupted native run identity from its checkpoint even if Observer loss prevented the accepted prompt ID from reaching SQLite. Ambiguous or unmatched pending work stays fenced. If the Observer dies after importing the settlement, recovery finishes the same operator path and preserves the original `native_stop_confirmed: false`; only final exact-claim settlement clears the private origin marker.

This API is absent from agent tools and public routes. `Editor.resume_run(run.id)` restores context without calling a provider or replaying an effect. A resumed run becomes ready only after its checkpoint and confirmed stop succeed; failed settlement keeps the fence and returns the real error. A later explicit steer starts a new turn, not the interrupted continuation.

### Reconcile a candidate process

Checks, previews and deployment share one durable lease at `$DOCS_DATA_DIR/candidate-effects/active-process-lease.json`. Each child reserves a launch generation before spawning. `process-lease-receipt.json` retains identity-confirmed cleanup; an earlier step's receipt cannot release a newer child.

From the trusted editor console, use `OhMyJidoDocs.Candidates.reconcile_process_cleanup/0` after interruption. It stops dedicated orphan tasks and retries identity-safe cleanup, not the original effect. Missing or mismatched proof stays blocked across restart. Preserve the receipt and investigate; do not delete the lease or retry deployment to guess what happened. Confirmed local cleanup says nothing about the outcome already reached on Fly.

## Durability and backup

The editor uses SQLite WAL with one connection and a 5,000 ms busy timeout. `DOCS_DATA_DIR` also holds session checkpoints, workspaces, immutable candidates, adopted Git source versions and their pointer, publication snapshots and effect receipts. `DOCS_SOURCE_ROOT` remains the original seed. The example does not encrypt either store.

Startup creates/restricts `DOCS_DATA_DIR` to mode `0700` before writing publication/session state. Start setup with `umask 077`. If the database or publication root is outside that directory, protect its parents and files yourself; the app does not chmod arbitrary external parents.

For a consistent cold backup:

1. Finish or cancel work, stop previews, then stop the editor.
2. Archive the complete data directory, including SQLite/WAL files, managed Git versions and pointers. Include any external database/publication overrides and the seed checkout you intend to retain.
3. Store the archive in operator-owned encrypted storage outside served, agent and build paths. Preserve permissions and stable absolute paths. Back up credentials through your own vault, not event exports.
4. Restore while stopped, check ownership/paths, then start the same compatible application/SDK version.
5. Inspect and reconcile actual source and external state before explicitly continuing. Restore marks interrupted/uncertain effects; it never reruns a model turn, command, publication or deployment automatically.

The public image is disposable: redeploy its reviewed source release. It has no studio volume to back up and makes no replication/failover promise.

## Security boundary

This is a trusted-editor reference application, **not an OS sandbox**. Private working directories, homes, environments and build caches prevent accidental inheritance and cross-run cache mutation. Process cleanup is not a kernel resource quota. Deliberately authored code can still access the editor OS user's files/network or escape a process session. Do not approve hostile code or grant execution authority to untrusted users. Add OS/user/container isolation and network/resource policy when your threat model requires it. Whole-host failure or escaped processes can leave effects uncertain; recovery records that uncertainty instead of retrying them.

Authentication protects runs, questions, diffs, candidate controls and preview access. Markdown uses pinned MDEx with unsafe HTML disabled and its sanitizer enabled; it is never compiled as HEEx. Only reviewed immutable snapshots are public in editor mode. Draft workspaces are not public content roots.

### Write pages the renderer can load

Every file under `priv/docs` must be UTF-8 Markdown with a `.md` extension and a lowercase slug matching `~r/\A[a-z0-9]+(?:[-\/][a-z0-9]+)*\z/` after removing that extension. For example, `getting-started.md` maps to `/docs/getting-started`. A non-Markdown file, symlink or unsupported entry rejects the whole inventory; put assets elsewhere. Pages sort alphabetically by path. The first level-one `# ` heading supplies the title, with the slug as fallback.

Links are not rewritten. Use `/docs/<slug>` for in-site links. In published pages, use absolute GitHub URLs for repository guides; this checkout uses `https://github.com/mattneel/oh_my_jido/blob/jido-v3-preview/docs/...`.

| Inventory limit | Maximum |
|---|---|
| Pages | 128 |
| Bytes per page | 256 KiB |
| Total content | 4 MiB |
| File/directory entries | 1,024 |
| Directory depth | 8 |

Oversized directory listings are rejected before sorting/descent. Reads stay bounded even if a file grows after stat. Traversal and modified immutable snapshots fail closed.

## Checks and branch versions

Run the example's complete gate from `examples/docs_site`:

```bash
mix ci
```

It runs warnings-as-errors compilation, format checks, behavior tests, strict Credo with ExSlop, Dialyzer, zero-clone ExDNA and Reach architecture/smell checks. Candidate checks are a separate compile/test/assets/release pipeline; they exclude only recursive `candidate_integration` lifecycle tests, not the parent acceptance suite. Run the root library's `mix ci` separately. A local preview is not evidence of an external deployment.

This checkout uses the native Jido V3 preview stack. Keep each branch's Mix dependencies and build directories separate.

| Branch | SDK and durable storage |
|---|---|
| `master` | Jido / Jido.AI / Jido.Action 2.4; patched Jido and ReqLLM snapshots. File sessions use `{Jido.Storage.File, path: ...}`. Set an explicit active model or `model_roles` in library integrations; bare Jido 2.4 aliases point at a retired model. |
| `jido-v3-preview` | Pinned native Jido `3.0.0-beta.1`, Jido.Action `3.0.0-beta.12` and a native V3 Jido.AI snapshot whose upstream version metadata still says `2.3.0`; vendored ReqLLM. File sessions use `{Jido.Persistence.File, path: ...}`. The library supplies provider-qualified defaults, but this studio still requires `DOCS_MODEL`. |

Exact SDK revisions are in the branch's `vendor/*/UPSTREAM.json` records. Current verification and historical evidence are linked from [project status](../../docs/project-status.md), rather than repeated in this operating guide.

## Related

- [Library documentation](../../docs/README.md)
- [Getting started with the library](../../docs/getting-started.md)
- [Production operations](../../docs/operations.md)
- [Permissions and approvals](../../docs/guides/permissions-and-approvals.md)
- [Security](../../docs/guides/security.md)
- [Packaged public documentation](priv/docs/index.md)
