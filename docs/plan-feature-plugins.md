# Maprisma feature plugins

Status: implementation in task 082; final integration checks and independent review pending.
User direction, 2026-11-20: make Maprisma an AI command center, keep Reports,
AI Project Center and Ask AI as separate plugins, and leave room for more plugins.

## Boundary and update model

The Flutter shell owns navigation, themes, accessibility, shared native widgets and
the existing service transport. Each feature owns its state, operations and long-lived
backend process. The first feature identities are `reports`, `ask-ai` and
`ai-project-center`. Native navigation contributions are described by
`flutter_app/lib/features.dart`; generic service entry points are `features.list`,
`features.call`, `features.summary` and `features.shutdown`.

The backend API is versioned JSON over private standard input/output. It does not
require a listening TCP socket or a shared Dart object ABI. A compatible backend
update can replace a feature executable without rebuilding the Flutter app.
Native Flutter presentation is compiled with the shell: adding a new widget,
interaction or navigation capability still requires a shell update. This release
does not promise that arbitrary downloaded Dart can become native Flutter UI.

Feature source modules remain coherent even in development's embedded mode:

| Area | Ownership |
| --- | --- |
| `feature_plugins.dart` | Discovery, executable verification, process protocol, opaque handle ownership and shutdown |
| `feature_routes.dart` | Generic host entry points and adapter-to-project profile bridge |
| `feature_worker.dart` | Process entry point and permitted feature operations |
| `feature_reports.dart` | Reports library, pending drafts and report operations |
| `feature_ask_ai.dart` | Ask AI helper selection, proposals, checked plan creation and delivery |
| `features/ai_project_center.dart` | Saved projects, plan approval, team assignments, process lifecycle and handoffs |
| `flutter_app/lib/features.dart` | Native feature descriptors, page/action slots and UI API compatibility |

Shared resource discovery and existing checked configuration/apply operations stay
in the core. A feature uses those services rather than defining a second resource map.
The existing Reports and Ask AI routes remain compatible for their native views and
existing clients. The host routes returned opaque handles back to their owning
feature process for subsequent status, cancel or apply requests.

## Executable discovery and trust

Bundled executables live under `features/<id>/plugin` in the application bundle.
User-installed updates live under Maprisma's data directory at
`feature-plugins/<id>/`. An update contains `feature.json`, `SIGNATURE` and `plugin`.
The manifest identifies the feature, API version and executable SHA-256 digest.
The author signature uses the separate `maprisma-feature` namespace. The host
checks compatibility, signature, file types and executable digest before launch.
Discovery does not execute hooks. A rejected installed candidate must surface an
error rather than silently run that candidate.

These are executable feature plugins. Existing agent/provider add-ons remain under
their current data-only policy; a new field in an agent add-on does not grant it
permission to load executable feature code. This first release supports trusted
first-party features. Process separation helps ownership and failure handling;
it is not an OS sandbox or protection from a malicious trusted executable.

Verified executable bytes are staged into the private feature launch cache before
execution, so later changes to the installed source file do not substitute code
after verification. The process receives the host bundle root for shared resource
discovery. Each feature binary also implements its own worker mode: report
generation and Ask AI helper work use that feature version, rather than an older
generation worker from the host bundle.

The process begins with an `@hello` exchange containing its feature identity and
API version. Request IDs pair replies with callers. Requests/responses have size
bounds; timeouts, invalid replies and process exit disconnect the feature. The
host does not replay a failed mutation automatically. Existing opaque handles
from a lost process are not valid in a newly started process.

Handle ownership follows provenance, not shape. Every token a process issues
(`newHandle`, also when a route returns the bare 32-hex form without `core-`)
enters that process's bounded issued-handle registry. A result frame carries
`"handles": [...]`, the strings in that result the feature itself issued. The host
records only listed strings that occur in the result, so a same-shaped hash or id
is never taken for a handle; a plugin without this field is trusted only for the
prefixed form. A feature accepts a cross-domain follow-up only for a token in its
own registry. The registries (65,536 tokens, evicted by issuance order) keep far more
tokens than any handle store keeps alive; a handle older than that many later
handles stops routing across processes. A feature that stopped loses its entries
in the host.

In a source checkout without bundled/installed executables the same feature runs
embedded. This keeps tests and development usable, but a shipping build must
exercise the process implementation as well. An already active process keeps its
current version; updating its files must not replace the process halfway through
a project run. General online installation, automatic updating, hot replacement
and a public third-party feature marketplace are later work.

## Why this structure

Vibe Kanban documents reusable agent configurations and separate task execution
workspaces. Maprisma takes the separation between feature workflow and the agent
it launches, while retaining its own native resource map and local management.
[Agent profiles](https://www.vibekanban.com/docs/settings/agent-configurations),
[workspaces](https://www.vibekanban.com/docs/workspaces).

Flutter's documented deferred component delivery concerns Android and web, and
its native plugin model includes compiled platform code. A separately versioned
process protocol is a practical desktop backend update boundary. Flutter's remote
widget library also describes the limits of runtime descriptions: they compose
prebuilt components rather than supply arbitrary new native widget behavior.
[Flutter components](https://docs.flutter.dev/perf/deferred-components),
[native packages](https://docs.flutter.dev/packages-and-plugins/developing-packages),
[remote widgets](https://pub.dev/documentation/rfw/latest/index.html).

## Dart now, Rust where evidence supports it

The initial feature implementations stay in Dart, reusing the existing Reports,
Ask AI and operating-system integration. Dart can produce standalone native
executables. The process contract intentionally permits a Rust or other backend
later without changing Flutter presentation or feature identities.
[Dart compilation](https://dart.dev/tools/dart-compile).

Task 082 implements process ownership with a per-assignment subreaper supervisor
in the AI Project Center executable itself (see the AI Project Center plan). A
narrowly scoped Rust supervisor may eventually make sense for resource limits
or a measured parsing bottleneck. Rust does not automatically
provide correct checkpointing, child cleanup or safe replay; those remain protocol
and lifecycle requirements. For example, Rust's own process documentation requires
the caller to manage child termination and waiting. No wholesale core rewrite or
new performance claim is part of task 082.
[Rust child lifecycle](https://doc.rust-lang.org/std/process/struct.Child.html).

## Verification and future extension

During development run checks for changed feature modules, process transport,
protocol routes and affected native pages. At the end run the complete repository
suites once, as requested by Uwe on 2026-11-20; this task instruction supersedes
the earlier rule limiting full suites to pre-push checks. Report environmental
failures and existing baselines separately from confirmed regressions.

Acceptance includes feature isolation, version/signature rejection, private stdio
framing, handle ownership, process loss, shutdown, embedded development fallback
and replacing one compatible backend while the host remains unchanged. Add a new
feature through a descriptor, explicit operations and a reviewed contract. New
capabilities enter the shared host only when a feature needs a reusable primitive.
Changes to executable installation trust or native presentation require their own
review rather than a hidden extension of the current contract.

Claude's review attempt could not reach its API because DNS was unavailable;
Antigravity could not open its required local socket in this execution environment.
Their independent review is pending. These failures are not CLEAN review rounds.

Final validation and outstanding host checks: [task 082 review](reviews/082-ai-project-center.md).

The backend choice, including an embedded fallback, is pinned until restart. Public project operations cannot call private worker control methods. The continued runtime and widget verification is in the [task review](reviews/082-ai-project-center.md).
