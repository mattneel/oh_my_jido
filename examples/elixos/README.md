# Elixos-owned integration example

**Historical stable-Jido integration, not a V3 acceptance example.** The human
explicitly assigned Elixos integration to the Elixos repository. This adapter
and its recorded commands/evidence remain intentionally unmigrated here; in
particular, its `Jido.Storage` references describe the stable SDK. Do not run
these instructions as native V3 proof. Use `../plain_mix` and `../jido_agent`
for this branch's native integration; the source-first docs-site example has
its own acceptance gates.

This separate Mix project has two explicit profiles. The independent host-test
profile compiles selected **current working source** from Elixos;
`ELIXOS_SOURCE` is the trusted `os/` Mix project directory (default: the sibling
checkout's `os/`). No Elixos module enters the core Oh-My-Jido application.
The human-approved native factory profile instead compiles this adapter against
the **complete OS project** with its target build and authoritative lock.

In the host-test profile, `host_source/` compiles selected actual Agents, Session, Ask, Browser/CDP,
Candidate/JSON child, Health, Image, Privileges and supporting package/service
sources into an independent `:elixos` application. It deliberately has no
`Elixos.Application` callback: compilation/testing does not boot the full OS,
start a browser binary, connect a database, or open guest shim descriptors.
The selected package/Oban definitions require the already-installed pure-BEAM
CDP/Ecto/Postgrex/Oban dependencies; no graphics/NIF/browser download is selected.
The project reuses actual installed declarations and lock pins rather than
hand-installing packages with Igniter integrations. Jido/ReqLLM overrides and
configuration come from the already-installer-applied core project. The additional
installer-less transitive sources are pinned from Elixos' current lockfile
(Ecto 3.14.2, Decimal 3.2.0, DBConnection 2.10.2 in the inspected checkout).
No private package or invented private-repository pin is introduced.

## Independent integration commands

From this directory, with those local dependency sources already present:

```sh
ELIXOS_SOURCE=/home/autark/src/elixos/os HEX_OFFLINE=1 MIX_ENV=test mix deps.get --check-locked
ELIXOS_SOURCE=/home/autark/src/elixos/os MIX_ENV=test mix compile --warnings-as-errors
ELIXOS_SOURCE=/home/autark/src/elixos/os MIX_ENV=test mix format
ELIXOS_SOURCE=/home/autark/src/elixos/os MIX_ENV=test mix test
```

These are handoff commands, not checks executed during authoring. The tests use
real service modules and disposable directories:

- Distinct requester group leaders set real `Elixos.Session` roots before
  crossing `Elixos.Agents`; actual Actions read each root. Image's journal and
  Agents snapshots retain only the lifecycle identity. A stopped owner restores
  the library conversation from `Jido.Storage.File`.
- Real `Elixos.Ask` subscriptions observe questions. Invalid replies, false,
  dismissal, deadlines, owner death and native run cancellation fail closed.
  The default is never applied as consent.
- An already-connected disposable Browser service runs **actual
  `Elixos.Browser` callbacks and `CDPEx.Page` operations** against a stateful,
  in-process CDP command/lifecycle fixture. Navigation, evaluation, PNG capture,
  ownership refusal, lease release and in-flight timeout serialization have
  assertions. No browser launcher, HTTP server or network is used.
- Actual `Elixos.Candidate` builds/tests disposable projects through the current
  JSON-only child ERTS boundary. Tests inspect child OS identities, bounded
  receipts, tool-bytecode provenance, denial before compilation, failed suites,
  retained Health evidence and the absence of authored modules/host mutation.
- Actual Privileges/Control clients use disposable reply/sink fixtures to prove
  the fixed HELPER wire and validated reply, without spawning a helper or sending
  a guest NEXT/COMMIT/reboot request.

These fixtures do **not** establish the complete OS baseline suite, native browser
platform behavior, T10 generation promotion, boot health, COMMIT or fallback.

## Supervision and caller roots

On a real Elixos instance, place this ordinary child beneath a host-owned
supervisor (for example the existing package service supervisor):

```elixir
{ElixosHost.Supervisor,
 runtime: ElixosHost.Coding,
 storage_path: "/priv/oh_my_jido/sessions",
 credentials: {OhMyJido.Auth, broker: MyHost.AccountBroker},
 deployment_enabled: false}
```

The host already owns and supervises `Elixos.Agents`, `Elixos.Ask`, Image,
Browser and Privileges. This child neither replaces nor starts those services.
The credential provider is an explicit host option; opaque account references,
not provider keys/broker PIDs, belong in recorded session options.

From the requester's IEx/SSH process:

```elixir
{:ok, candidate_workspace} = Elixos.Candidate.checkout("/priv/workspaces/coding-session")
{:ok, ^candidate_workspace} = Elixos.Session.cd(candidate_workspace)
{:ok, owner} = ElixosHost.open(id: "coding-session",
  account: "opaque-approved-account", permissions: [:read, :edit, :exec, :ask])
session = ElixosHost.SessionOwner.session(owner)
:ok = OhMyJido.subscribe(session, self())
{:ok, run} = OhMyJido.prompt(session,
  "Repair the repository defect and run its tests without changing unrelated behavior")
```

`open/1` captures `Elixos.Session.cwd_for(Process.group_leader())` **before**
entering Agents/Runtime. There is no global cwd/env mutation or lookup of the
supervisor's group leader as the workspace. Lifecycle snapshots contain only
`%{version: 1, session: %{runtime: runtime_atom, id: binary}}`; coding checkpoints
and conversation belong to the library's Jido storage. Restore preserves the
recorded root and does not replay effects. `ElixosHost.snapshot(id)` rejects an
active explicit checkpoint; `ElixosHost.stop(id)` uses the actual Agents service.

## Human authority

Authorization of execution, network, page script, candidate execution,
privileges and deployment goes to the actual Ask queue. The adapter blocks its
supervised worker, never the session coordinator. It watches the session/run,
sets a finite trusted deadline, and accepts only an explicit boolean `true` from
Ask for effect consent. Defaults, dismissed questions, timeouts and late replies
cannot authorize anything. The existing trusted host front-end selects and
answers a specific `Elixos.Ask.pending/0` question through `answer/2` or
`dismiss/1`; there is no automatic approval loop.

Granting a capability is not approval of an effect. An untrusted question text,
repository instruction or model default cannot grant host policy. Fixed helper
names must appear in both the host's `helpers: ["name"]` and the shim allow-list.
`elixos_helper` accepts only `name`; command, argv and UID escalation do not exist.

## Candidate ownership and opt-in proposal

Grant `:candidate`, then register the host Action through the public API:

```elixir
:ok = OhMyJido.register_tool(session, ElixosHost.Tools.Candidate)
```

The host supplies trusted `build_options` (system source, dependency directory,
selected tool tests, target, timeout, optional Image/Control handles). On guests
the declared parent comes from `Elixos.Boot.Env`; host-only demonstrations must
supply `parent_generation` explicitly. Model requests cannot supply provenance,
a host MFA, a service PID or build policy. Provenance uses the durable library
identity, selected model and hashes of the actual registered tool BEAMs.

`build` returns a string `candidate_id`; later test/evidence/propose operations
reopen it via actual `Elixos.Candidate.open/2` and enforce its session provenance.
No candidate handle/PID or credential is stored in lifecycle snapshots. Builds
and suites isolate VM state in non-distributed, JSON-only child ERTS; they are
**not** filesystem/network sandboxes. A live host must approve execution and
supply the appropriate sandbox for authored code.

`propose` requires **all three**: the session's `:deploy` grant, trusted
`deployment_enabled: true`, and a fresh human confirmation. The current actual
Candidate service still validates immutable tested bytes, stages through Image,
and writes normal NEXT. The adapter reports `next_written: true` and
`promotion_acknowledged: false`; it never reboots, sends COMMIT or pretends NEXT
is a promotion acknowledgment. Established Elixos boot/health/COMMIT/fallback
ownership remains unchanged. Proposal is disabled in default supervision and
no successful proposal is exercised by these host tests.

## Singleton browser contract and limits

Browser access is disabled by default. Enabling it requires host options:

- `browser_enabled: true` to supervise one `BrowserLease` and one bounded OTP
  task supervisor.
- `browser_exclusive: true`: a trusted assertion that **all** users of this
  singleton are routed through the lease. Direct outside calls to
  `Elixos.Browser` cannot be intercepted by this adapter.
- `network_boundary: {HostNetworkBoundary, options}` implementing
  `authorize(context, request, options)`. It must attest/enforce the live egress,
  redirect, popup and download policy **before** returning `:ok`; an initial URL
  allow-list alone cannot sandbox the existing Browser API. Arbitrary page eval
  also requires this boundary because script can issue network requests.
- Explicit `:browser`, `:network` and `:browser_script` grants. Both navigation
  and arbitrary eval require network/script effect authorization. Snapshot uses
  the fixed read-only capture script with separate script authorization.

For the extra native surface, register `ElixosHost.Tools.Browser`; it implements
navigate, snapshot, eval, screenshot and lease release using the actual public
`navigate/1`, `eval/1` and `screenshot/0` services. One library identity owns the
singleton across operations. Others cannot read, replace or release its page.
An operation deadline retains its in-flight lease until the real late reply;
a worker/service failure with uncertain effects poisons admission until the host
reconciles it. The lease server is temporary, not automatically restarted into
an unsafe empty ownership state. Session death releases only an idle, confirmed
lease. The shared native browser is never stopped by session cleanup.

The real API has **no safe page-close operation**. Core Browser `close` returns
`:browser_page_close_unavailable`; click/fill likewise return unavailable rather
than inventing native service methods. `release` reports `released: true,
page_closed: false`; `close_session/2` confirms only lease cleanup, not native
page/process closure. The core close-requiring browser smoke therefore cannot
claim complete cleanup against this API. Cookies/storage and the native page
remain shared; this is serialized single-user access, not isolated native
browser contexts. Live browser prerequisites include the guest's verified
browser manifest/binary and an enforced network boundary.

## Native factory packaging and exact T10 guest workflow

**Implemented source, not an exercised guest result.** The following is a
human-started, deterministic **native Jido.AI scripted ReAct** scenario using
actual public library sessions, tools, child ERTS builds, real ExUnit suites,
Image, Ask and the inherited shim channel. Only the model boundary is scripted;
there is no fake browser, fake successful command, mock shim, API key or network.
This is not evidence of live-provider coding potency. That proof is separate.

### Factory contract

Elixos ADR-084 authorizes the installer-less library as a native pure-BEAM
dependency. Elixos' existing Jido dependency changes source in place to the
licensed canonical `vendor/jido`; ReqLLM keeps the canonical library's
`vendor/req_llm` path override. Both `UPSTREAM.json` inventories, local notices,
licenses, source bytes and all applicable Hex checksums remain inputs.
The upstream inventories describe original snapshots, not hashes of the local
privacy patches: the additional selected-source receipt binds the actual files.
Existing OS Jido wiring is preserved; no additional installer is guessed/run.

The real adapter is built separately as an ordinary Mix app against **all**
of Elixos with `ELIXOS_FACTORY=1`, using the OS dependency/build paths and
`os/mix.lock`. The reduced host-test `host_source` application is not packaged
as the OS. `/factory/lib/elixos_host-0.1.0/{ebin,priv}` is an ordinary OTP package,
not a copied fork, extra VM, runtime transport, hot-loader or unrestricted RPC.
The factory adds its existing ebin paths normally and starts no coding runtime
implicitly. The human's T10 call supervises one beneath `Elixos.Package.Services`.

`scripts/stage-coding.exs` hashes selected canonical source files and requires
an explicit reviewed pin to stage them. Generated `_build`, `deps`, `.git`
and `tmp` trees are excluded; source symlinks are rejected. Factory dependency
resolution must leave the approved OS lock byte-for-byte unchanged.
The factory's own OTP **29.1.1** / Elixir **1.20.4** emits the BEAM, never the
host OTP 28 build. Inspect:

- `/factory/coding/source.json`: every selected canonical source path, byte
  count and SHA256, the combined source pin, and omitted optional backends.
- `/factory/coding/beams.json`: source-receipt digest, exact OS-lock digest,
  complete copied OS/test/vector/assembly-input inventory and its combined
  system-source SHA256, compiler/ERTS/architecture identity, every factory
  application and its required applications, emitted BEAM paths and SHA256s,
  and the preserved application redistribution notices.
  Assembly controls are retained under `/factory/coding/inputs`; licenses and
  notices also live in the ordinary application `priv/licenses` directories.
- `/factory/source/oh_my_jido/`: the exact licensed canonical source inputs,
  including this adapter, guest control scripts and the userland fixture.
- `/factory/source/os/`, `/factory/source/spec`, `/factory/source/MILESTONE`:
  real system tests, source, fixtures and vectors. Mix and ExUnit are included;
  host caches are not. Only the test-repository rebuild signing key is omitted.

`ElixosHost.FactoryReceipt.verify/0` checks these bytes, source pin, lock,
target runtime, unique app closure, and native loaded-code identities. It
does not replace the actual boot transcript or external quality gate.

### Build and create only a disposable disk

Run these commands **as the human/main verification owner**, after all canonical
source changes have landed. They are handoff commands; this assignment has not
executed a build, test, formatter, QEMU instance or disk effect.

```sh
cd /home/autark/src/elixos
elixir scripts/stage-coding.exs pin /home/autark/src/oh_my_jido
# Review the checkout and paste that complete digest at the prompt:
read -r -p 'Reviewed canonical source SHA256: ' ELIXOS_CODING_SHA256
export ELIXOS_CODING_SHA256
export ELIXOS_OH_MY_JIDO_SOURCE=/home/autark/src/oh_my_jido
scripts/build-image.sh x86_64
```

The native builder regenerates `apko/apko.lock.x86_64.json` against the new
factory APK. Retain that resulting lock together with the APK/SBOM/image
digests; do not copy a stale image lock or hand-invent an APK checksum.

Do **not** run `make image`, `make qemu`, or unqualified `scripts/mkdisk.sh`:
the first/last recreate the default disk. `build-image.sh` alone does not.
A new private build directory lets the existing native disk recipe seed a
fresh sparse disk with the **new** service image and packaged toolchain without
opening or overwriting `build/disk.img`:

```sh
T10_BUILD=$(mktemp -d /home/autark/src/elixos/build/t10.XXXXXX)
mkdir -p "$T10_BUILD/apk" "$T10_BUILD/x86_64"
ln -s /home/autark/src/elixos/build/apk/x86_64 "$T10_BUILD/apk/x86_64"
ln -s /home/autark/src/elixos/build/x86_64/system.squashfs "$T10_BUILD/x86_64/system.squashfs"
ELIXOS_BUILD="$T10_BUILD" DISK_SIZE=4G scripts/mkdisk.sh x86_64
export ELIXOS_DISK="$T10_BUILD/disk.img"
QEMU_MEMORY=4096 scripts/run-qemu.sh
```

The QEMU helper already uses `-nic none`. Retain the actual serial console
transcript in a human-owned recording and keep this disk until evidence is
exported. Never add recovery/safe/generation overrides or a host-root helper.
The driver also requires normal boot, only `lo`, and default Health policy.

### Healthy candidate, health, automatic COMMIT and continuity

1. Wait for factory generation 0's **actual** Health and automatic COMMIT.
   IEx can read `File.read!("/priv/boot.state")`; require current/last_good 0
   and attempts 0, not merely an available prompt.
2. From guest IEx, explicitly evaluate the pinned launcher:

   ```elixir
   Code.eval_file("/factory/source/oh_my_jido/examples/elixos/guest/healthy.exs")
   ```

   It returns a finite driver/session identity and uses only a fresh
   `/priv/oh_my_jido/t10/healthy/project`. The fixture is a **non-protected
   userland Mix project**, not OS or framework source. Native ReAct reads
   `mix.exs`, its test and implementation, then snapshot-edits only `value - 1`
   to `value + 1`. It builds Candidate in a separate ERTS and checks that no
   authored code entered the active VM and that global cwd did not change.
3. Inspect each actual Ask question and approve only its specific effect:

   ```elixir
   Elixos.Ask.pending()
   # Read the selected question's prompt, operation and candidate ID first:
   Elixos.Ask.answer(question_id, true)
   # To refuse instead:
   # Elixos.Ask.dismiss(question_id)
   ```

   There are separate human grants for **build**, **test**, and **propose**.
   No code automatically answers questions. Test executes complete portable OS,
   selected native host-tool, and userland candidate suites. The driver rejects
   empty/skipped/failed suites, requires distinct non-distributed child OS PIDs,
   verifies session/model/actual tool-BEAM provenance and the sole user module,
   and proves an untested candidate cannot be proposed. It checkpoints real
   conversation/effects/retained facts through `Jido.Storage.File` before NEXT.
4. Inspect `ElixosHost.T10.status(:healthy)` and the driver receipt. Require
   `status: :next_written` with a real positive generation, **not** a completed
   scripted sentence. The final native turn needs a fresh `:deploy` grant,
   host deployment opt-in and human confirmation before normal Candidate
   proposal. Neither the Action nor the driver sends COMMIT or reboots.
5. After reviewing all receipts, the human alone requests a normal reboot:

   ```elixir
   :ok = Elixos.Shim.Control.reboot()
   :init.stop()
   ```

   `run-qemu.sh` uses `-no-reboot`, so QEMU exits on this kernel reboot.
   Relaunch **the same disposable disk** from the host:

   ```sh
   QEMU_MEMORY=4096 scripts/run-qemu.sh
   ```

6. Wait for normal boot's verified live-image Health, all three real suites,
   automatic COMMIT and the shim's `commit generation=<healthy>` line.
   Health compares actual loaded VM module MD5 identities against SHA256-
   verified generation store BEAM; child suites run those verified bytes,
   not a fresh compilation masking bad running code. AutoCommit's write
   receipt alone does not prove sealing: require boot.state last_good/current
   equal the healthy generation, attempts 0, and no commit-refused log.
7. Explicitly resume and check the checkpoint in guest IEx:

   ```elixir
   Code.eval_file("/factory/source/oh_my_jido/examples/elixos/guest/verify_healthy.exs")
   ```

   This restores the **same** durable session, conversation, retained candidate
   and generation identities, then runs a new native scripted read. It never
   replays the edit, tests or proposal. The result is
   `:guest_postconditions_verified`, with `serial_transcript_required: true`.

### Benign boot exception and normal last-good fallback

Only after the previous verification:

```elixir
Code.eval_file("/factory/source/oh_my_jido/examples/elixos/guest/fallback.exs")
```

Inspect/answer the three new scoped Ask approvals as above. This creates a
different userland workspace/session, repairs it through the same real Actions,
and runs all three suites before proposal. The only deliberate failure is its
trusted boot spec invoking `OhMyJidoGuest.Workload.boot(:fallback)`, whose
known RuntimeError is also explicitly tested. It does not corrupt a store blob,
replace a protected module, unstick code, change Health, or use any helper.
The candidate fingerprint includes its full manifest/provenance and trusted
build/boot/test policy as well as source and BEAM; changing them after testing
invalidates proposal.

Inspect `ElixosHost.T10.status(:fallback)`, then use the same human reboot
commands and relaunch the same disk. Keep the default attempt policy. The
actual boot MFA fsyncs one launch-only observation under the fallback scenario
directory immediately before raising. Child test workers have their shim
environment removed, so suite invocation cannot manufacture this boot evidence.
The shim must log each failed normal attempt and:

```text
elixos-shim: fallback to last_good=<healthy> after 3 attempts of generation=<bad>
elixos-shim: plan generation=<healthy> mode=normal attempt=1
```

Use the exact prefix/boot spelling in Elixos `docs/PROTOCOL.md` if matching
the transcript programmatically. Wait for healthy generation's automatic
Health/COMMIT again, then:

```elixir
Code.eval_file("/factory/source/oh_my_jido/examples/elixos/guest/verify_fallback.exs")
```

Verification requires normal last-good boot, real committed boot.state,
successful Health/AutoCommit receipts, matching loaded code, ordered actual
bad-generation launch observations, **no** bad-generation AutoCommit receipt,
and restoration/read of the failed candidate's own durable session. Parent
verification must additionally match the real serial exceptions, attempt and
fallback lines, absence of bad-generation commit, and no kernel panic.
Neither `:guest_postconditions_verified` nor source tests alone declare T10 green.

### Retained evidence and execution risks

- `/priv/oh_my_jido/t10/{healthy,fallback}/stage.term`: durable identities,
  native scripted call history/run IDs, source/runtime pin, candidate ID,
  parent and proposed generation. `status/1` only reads it, never retries.
- The same directories retain immutable `driver-*.term`, latest `driver.term`,
  `verified-*.term`/`verified.term` and fallback `boot-attempts.log`.
- `/priv/oh_my_jido/t10/sessions/`: native Jido file-storage checkpoints.
- `/priv/evidence/candidates/<id>/`: exact userland/system snapshots, build
  and test receipts, child JSON requests/reports, logs and suite runtime dirs.
- `/priv/evidence/<generation>/`: proposal, health-run evidence, retained
  `health-*.term`/`health.term` and `auto_commit-*.term`/`auto_commit.term`.
- `/priv/generations`, `/priv/store`, shim-owned `/priv/boot.state`, any
  `/priv/crash` files, immutable factory receipts and the actual serial
  transcript complete the parent-owned acceptance evidence.

Candidate's child ERTS is VM-state/crash isolation, **not** a filesystem sandbox.
This scenario is restricted to the reviewed fixture in a disposable no-NIC
guest; it does not grant permission for arbitrary OS source execution.
Full portable OS/tool health in target OTP/musl, its NIF/service assets,
runtime sizing, image assembly, shim sealing, and actual fallback remain
integration risks until parent verification runs. Failures retain evidence;
do not suppress them, narrow suites, repeat a workspace, or auto-approve.
Use a new disposable disk for a new end-to-end attempt.

Optional **QuickBEAM** and **Python/Snakepit/SnakeBridge** remain outside the
default runtime core and are not selected solely for T10. The separate native
Eval profile is implemented in Elixos under **ADR-092**; target acceptance is
still **unverified**, not waived. Neither host OTP-28 artifacts nor a package
receipt establishes F05/E01–E07 guest behavior.

## Optional native Eval profile: both Linux targets

The external Elixos checkout now owns native `melange/factory-eval.yaml`,
`melange/coding-eval-python.yaml`, `apko/apko-eval.yaml` and
`scripts/coding-eval/` packaging/configuration/smoke sources. See
[the complete parent-owned build/guest procedure](../../../elixos/docs/notes/coding-eval.md)
in that checkout. No core library/vendor code is copied into another runtime.

The separate profile compiles the canonical optional-backend branches with
target **OTP 29.1.1 / Elixir 1.20.4** before release assembly, retaining the
base OS lock and a separate merged optional lock. It uses QuickBEAM **0.11.3**
upstream checksummed **x86_64/aarch64-musl** artifacts, source-builds the actual
OXC **0.19.0** native dependency crates where upstream musl artifacts do not
cover them, and packages Alpine **CPython 3.14.8** with pinned native
**grpcio 1.84.0**, **protobuf 7.35.1**, numpy and typing-extensions wheels.
The canonical **MIT-licensed private-diagnostics Snakepit 0.14.0 snapshot**
and its unchanged Python SDK/stubs are mandatory; pristine Hex workers are
not a substitute. Every emitted source/BEAM/NIF/native-link identity is
builder-derived, checked and retained, never invented in source.

From the external checkout, use `scripts/stage-coding.exs pin-eval SOURCE`
and explicitly select the reviewed `ELIXOS_CODING_SHA256`. Then:

```sh
ELIXOS_EVAL_PROFILE=1 ELIXOS_BUILD="$PWD/build-eval" \
  MELANGE="$PWD/build/tools/melange" APKO="$PWD/build/tools/apko" \
  ELIXOS_OH_MY_JIDO_SOURCE=/home/autark/src/oh_my_jido \
  scripts/build-image.sh x86_64 aarch64
```

This refuses the default `build/` output directory and keeps optional apko
locks under `build-eval/locks/`. It does not create or overwrite any disk.
The operations guide gives guarded separate disposable-disk/no-NIC guest
commands for both architectures; existing default `build/disk.img` remains
untouched. Parent-owned builds require the existing pinned native build
tools and, when cross-hosting the target recipe, an explicitly configured
architecture runner. No installer or emulator is provisioned automatically.

After ordinary target boot/Health, use the real guest **IEx frontend**:

```elixir
Code.eval_file("/factory/coding/inputs/coding-eval/smoke.exs",
  evidence_directory: "/priv/eval-smoke-x86_64")
# In the separate aarch64 guest, use "/priv/eval-smoke-aarch64".
```

This is an actual finite three-backend Jido Eval scenario, not provider
inference or an unavailable-backend test. Each language must retain two
cells, read a real fixture through a granted Jido tool, deny that same tool
without authority, bound output, return errors/displays/artifacts, enforce a
deadline, cancel an active callback, survive an actual native worker exit,
require explicit reset and clean up its worker. Only complete success emits
the architecture-bound `verified.json` and SHA256 receipt. The parent must
also retain actual serial/no-panic evidence and all native/image receipts
for each architecture. No checks or guest proofs were claimed by these
source changes.

For ordinary interactive use, the optional release has actual `import Config`
settings and `Elixos.CodingEval.start(trusted: true)` /
`Elixos.CodingEval.open(permissions: [:read, :eval, :ask])`. It reuses the real
host/session frontend and native OTP/Snakepit prerequisites without starting
Snakepit's provisioning application. Worker PYTHONPATH is local; the host VM's
cwd/environment are unchanged. Elixir/JavaScript retain JSON-only separate
ERTS workers and Python retains Snakepit-only management. Trusted-code crash
separation is not an OS sandbox, and packaging grants no account or credential.
