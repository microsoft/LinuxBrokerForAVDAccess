# Service Management Portal Front End

This folder contains the **Service Management Portal** for the Linux Broker for AVD Access
solution. It is the administrator UI for managing Linux host VMs, scaling rules, and broker
activity. For the full solution context, see the repository [README](../README.md).

The portal is a **React 18 + TypeScript single-page app** built with **Vite** and styled with
**Tailwind CSS v4** using a custom glassmorphism design system. **Flask** remains, but as a
backend-for-frontend (BFF): it owns authentication, calls the Broker API on the operator's behalf,
and serves the built bundle.

## Architecture

```
Browser (React SPA)
   |  session cookie + X-CSRFToken
   v
Flask BFF  --- /login /getAToken /logout --->  Entra ID
   |  Bearer token from the server-side session
   v
Broker API
```

Why the BFF stays:

- MSAL's **confidential client** flow stays server-side. The API access token lives in the Flask
  session and never reaches the browser or `localStorage`. The callback checks broker capability
  before admitting an administrator.
- `Flask-WTF` CSRF protection still guards every state-changing request.
- Flask serves the SPA shell for **every** non-API path, so a bookmarked deep link or a hard
  refresh still resolves and React Router renders the right page.

## Administrator Access

**Ordinary AVD users have no portal access**, including read-only pages and direct BFF business
requests. Portal denial does not change AVD access. A single Entra account can have workspace
and administrator permissions separately:

| Permission | Authorized workflow |
| --- | --- |
| `WorkspaceUser` with `connect_as_user` from the approved native launcher | The user's own Linux workspace through AVD, not this portal. |
| `FullAccess` with `access_as_user` from the approved portal client | Administrator management of VMs, scaling, history, and settings, not credential checkout or impersonation. |

Require assignment to the portal enterprise application and synchronize those assignments with
the intended broker administrators. In this service, `CLIENT_ID` is the portal application's ID
and `API_CLIENT_ID` is the broker API's ID. They must match the broker's configured
`PORTAL_CLIENT_ID` and API audience respectively.

The BFF calls **`GET /api/me`** using its server-side API access token during the MSAL callback,
each signed-in session bootstrap, and **every management request**, before calling a business
endpoint. The frozen broker response is:

```json
{
  "subject": { "tenantId": "<validated tid>", "objectId": "<validated oid>" },
  "capabilities": { "manage": true, "connect": false }
}
```

Only `capabilities.manage === true` grants portal access. The subject must match the MSAL-authenticated
session's tenant and object IDs, and the session must have a valid, unexpired token lifetime.
ID-token roles are not API roles: the BFF never uses them for authorization and never decodes
an unverified API token. Capabilities are not cached across requests. An unavailable, malformed,
or missing capability endpoint fails closed; there is no fallback for older broker deployments.
Capabilities describe the current token/client, not all permissions the account may have in a
different workflow.

Signed-in non-administrators get a simple explanation and a working **Sign out or switch account**
link. They do not get a management shell or a sign-in redirect loop. The browser does not start
management queries until the server grants access. Revalidation pauses management queries and confirmation dialogs;
ordinary rechecks preserve unsaved administrator forms. Logout, a changed `(tenantId, objectId)`,
or authorization loss clears management query and mutation data and cancels outstanding queries.

**There is no portal checkout page, hook, navigation action, or BFF credential proxy.** Use the
approved AVD launcher for personal workspace access. The legacy `/vms/checkout` page is not
interpreted as a VM ID, and `/api/ui/vms/checkout` cannot issue credentials.

## Directory Layout

| Path | Purpose |
| --- | --- |
| `app.py` | Creates the Flask app, serves the SPA shell, exposes `/api/ui/session` and `/api/ui/dashboard`, and defines the JSON and SPA error handlers. |
| `config.py` | Reads cloud, Entra ID, and Broker API settings from environment variables. |
| `function_authentication.py` | `@login_required` requires live broker administrator authority, session expiry, and subject matching. Shared `401`/`403`/`503` authorization errors. |
| `function_api.py` | Authenticated Broker API helpers, request timeouts, JSON decoding, dashboard VM summary retrieval, history filter parsing, and paged history calls. |
| `function_bff.py` | Shared JSON plumbing: the `@broker_endpoint` error decorator, request-body helpers, and the paged history envelope. |
| `route_authentication.py` | Sign in, token callback, and sign out. Browser redirects, not JSON. |
| `route_vm_management.py` | VM JSON endpoints. |
| `route_scaling_management.py` | Scaling rule and scaling history JSON endpoints. |
| `route_host_settings.py` | Linux host settings JSON endpoints. |
| `static/dist/` | Vite build output. **Generated, not committed.** |
| `static/favicon.ico`, `static/images/` | The only hand-maintained static assets. |
| `web/` | The React application. |
| `tests/` | pytest suite covering the JSON contract. |

Inside `web/`:

| Path | Purpose |
| --- | --- |
| `src/styles/theme.css` | The whole design system: tokens, glass surfaces, badges, controls, tables, and the accessibility fallbacks. |
| `src/lib/` | `api.ts` (fetch wrapper, CSRF, 401 handling), `queryClient.ts`, `format.ts`, `theme.ts`, `vmLifecycle.ts`. |
| `src/types/broker.ts` | Every shape the BFF returns. |
| `src/hooks/` | `useSession`, `useBroker` (all TanStack Query hooks), `useHistoryQuery`, `useAutoRefresh`, `useConfirm`. |
| `src/components/Icon.tsx` | The 37 hand-authored inline SVG icons. |
| `src/components/ui/` | Design system primitives. |
| `src/components/layout/` | App shell, nav, breadcrumbs, theme toggle. |
| `src/components/data/` | `DataTable`, `Pagination`, `HistoryFilters`, `HistoryView`. |
| `src/pages/` | One file per screen, grouped by feature. |
| `src/test/` | Vitest setup and the shared provider-aware `render`. |

## BFF Endpoints

Every JSON endpoint lives under `/api/ui`. Anything else is either a server-side auth redirect or
a path that serves the SPA shell.

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/ui/session` | Bootstrap: `authenticated`, `subject`, `capabilities`, `user`, `version`, `csrfToken`. Signed-out sessions get a `200` with no user or subject and false capabilities; expired signed-in sessions get `401`. A verified non-admin gets a `200` with their own identity and `manage: false`, never management data. |
| GET | `/api/ui/dashboard` | `{stats, recentActivity, apiError}`. `stats.ready` comes from the broker summary; it is `null` (unavailable) when that count cannot be verified. Inventory fallback counters never imply checkout readiness. |
| GET | `/api/ui/vms` | |
| GET | `/api/ui/vms/<vmid>` | |
| POST | `/api/ui/vms` | Returns `201`. Unowned inventory only, not trusted host enrollment. New status must be `Available` or `Maintenance`. No username, AVD host assignment, owner, or lease fields. |
| POST | `/api/ui/vms/<vmid>/update-attributes` | Only `powerstate`, `networkstatus`, and `vmstatus`; unassigned `Available`/`Maintenance` hosts only. Assignment changes require guarded lease actions. |
| POST | `/api/ui/vms/<vmid>/delete` | |
| POST | `/api/ui/vms/<hostname>/release` | Keyed by **hostname**. Requires current `leaseId` and `leaseGeneration`. |
| POST | `/api/ui/vms/<vmid>/return` | Keyed by **VMID**. Requires current `leaseId` and `leaseGeneration`. |
| GET | `/api/ui/vms/history` | Paged. Filters in the query string. |
| GET | `/api/ui/scaling/rules` | |
| GET | `/api/ui/scaling/rules/<ruleid>` | |
| POST | `/api/ui/scaling/rules` | Returns `201`. |
| POST | `/api/ui/scaling/rules/<ruleid>/update` | |
| POST | `/api/ui/scaling/rules/<ruleid>/delete` | |
| GET | `/api/ui/scaling/log` | Paged. |
| GET | `/api/ui/scaling/rules/history` | Paged. |
| GET | `/api/ui/hosts/settings` | `{settings, hosts}`. |
| POST | `/api/ui/hosts/settings` | Only settings fields reach the API. The API derives the audit actor from the verified subject; the portal never supplies `updatedBy`. |
| POST | `/api/ui/hosts/settings/apply` | Returns a `message` and `tone` the client shows verbatim. |

Server-rendered routes that are **not** JSON: `/login`, `/getAToken`, `/logout`, `/health`,
`/favicon.ico`.

All listed business endpoints require `manage: true`, regardless of method or CSRF validity.
The only unauthenticated JSON bootstrap is `/api/ui/session`; `/health` is a minimal health
probe. BFF responses use `Cache-Control: no-store`.

### Inventory is not trusted host enrollment

**Add VM remains a supported administrator inventory action.** It does not make a host eligible
for checkout. Neither setting `Available`/`On`/`Reachable` nor reusing an old hostname grants trust.
Deleting and recreating a VM, or changing its hostname/IP endpoint, invalidates the previous host
enrollment and trusted inventory receipt.

A deployment operator must run the ARM-verified inventory import (`RegisterLinuxHostVm`) followed
by host identity enrollment (`RegisterBrokerHost`) for the exact current VMID, hostname, and IP.
Do not skip import because an inventory row already exists. `RegisterBrokerHost` alone cannot
repair a manually recreated or changed endpoint; the portal and runtime role cannot supply the
trusted inventory receipt.

On the first application of `046_bind_host_enrollment_to_verified_inventory.sql`, previous
hostname-only enrollments are intentionally deactivated. Complete that trusted import/enrollment
sequence for **every intended host**, even when its address is unchanged, before readiness checks
and resuming checkouts. These operations belong to the trusted deployment workflow, not the portal.

The dashboard uses the broker's verified `Ready` count. If that summary cannot be obtained, it
may still display inventory counts, but checkout readiness is explicitly unavailable rather than
inferred from editable host attributes.

### Administrative lease mutations

Admin VM records include `LeaseId` and `LeaseGeneration`. Return and release send exactly the
current values with the contract's lower-case request field names:

```json
{ "leaseId": "<current LeaseId>", "leaseGeneration": 7 }
```

The wire generation remains a **JSON number**, restricted to positive safe integers from
`1` through `9007199254740991`, inclusive. Both the BFF and React reject zero, fractions, and
unsafe values before forwarding a mutation; they never round, wrap, or convert the guard to a
string. SQL `BIGINT` and C# `long` storage do not imply full Int64 wire support: JavaScript and
older jq must preserve the same exact value.

The UI uses the displayed record's guards; when those are unavailable it fetches current VM
details rather than guessing a lease or generation. A missing/invalid guard prevents the
mutation. A stale `409` explains that the lease changed and refreshes VM data for review;
the client never automatically retries the mutation against a new assignment. The BFF requires
both guards and forwards them to `/api/vms/<vmid>/return` or `/api/vms/<hostname>/release`.
Returning a host does not make it available until the broker reports successful cleanup.

### Error contract

`@broker_endpoint` in `function_bff.py` turns broker failures into a predictable envelope:

```json
{ "error": "Unable to retrieve VM data. Please try again later." }
```

| Situation | Status |
| --- | --- |
| Client sent something unusable (`BadRequest`) | `400`, naming the field |
| Missing, invalid, or expired session/API token; capability subject mismatch | `401` on business routes; no redirect from a fetch |
| Authenticated but not authorized for administrator management | `403` |
| Capability service unavailable, missing, malformed, or otherwise unverifiable | `503`; no business call or authorization fallback |
| Stale administrative lease | `409`, with a safe instruction to refresh and review the assignment |
| Broker answered another `4xx` | The same status, preserving actionable validation errors |
| Broker answered `5xx`, timed out, or returned junk | `502` |
| Missing or stale CSRF token | `400` |
| Unknown `/api/ui/*` path | `404` JSON |
| Unknown page path (including legacy checkout) | `200` SPA shell; an authorized React client renders the not-found state |

Authorization errors also include a stable `code`: `session_expired`, `administrator_required`,
or `authorization_unavailable`. Broker authentication/authorization response details and MSAL
error descriptions are not echoed to the browser. A `401` shows an expired-session sign-in
state, `403` shows administrator-only access denied, and capability `503` offers retry/sign-out.
The same states apply to authorization loss during an existing page or mutation, clearing its
cached data. Other operation failures remain explicit page errors or toasts.

## Client Routing

Routes mirror the URLs the Jinja portal served, so existing bookmarks and runbook links still
resolve: `/`, `/profile`, `/vms`, `/vms/add`, `/vms/history`, `/vms/:vmid`,
`/vms/:vmid/update`, `/scaling/rules`, `/scaling/rules/create`, `/scaling/rules/history`,
`/scaling/rules/:ruleid`, `/scaling/rules/:ruleid/update`, `/scaling/log`, `/settings/hosts`.

## Design System

Everything lives in `web/src/styles/theme.css`. Tailwind v4 is configured **in CSS**; there is no
`tailwind.config.js`.

- Theme-dependent values are runtime custom properties on `:root` and `[data-theme="dark"]`,
  exposed to Tailwind through `@theme inline` so one utility works in both themes.
- The theme is switched by `data-theme` on `<html>`, set before first paint by the inline script
  in `web/index.html` and toggled at runtime by `lib/theme.ts`, which persists to `localStorage`
  under `lb-theme`.

| Class | Use |
| --- | --- |
| `.lb-glass` | The primary translucent surface: blur, border, shadow, and the specular top hairline. |
| `.lb-glass-strong` / `.lb-glass-soft` | More or less opaque variants of the same surface. |
| `.lb-inset` | A flat inner panel. Use inside `.lb-glass`; **never nest a second blur**, which compounds into mush behind text. |
| `.lb-interactive` | Hover lift. Only for a card that is itself a link or button. |
| `.lb-badge` + `.lb-tone-*` | Status pill. Tones: `ok`, `accent`, `info`, `warn`, `danger`, `neutral`. |
| `.lb-field` | Inputs, selects, and textareas. |
| `.lb-btn` | Button base; variants are applied by the `Button` component. |
| `.lb-table` | Data table with a sticky header. |

Use the semantic Tailwind colours (`text-ink`, `text-muted`, `text-subtle`, `text-brand`,
`border-hairline`) rather than hard-coding palette values, so both themes come from one rule.

### Accessibility rules that must not be broken

Glassmorphism is easy to make unreadable. These are requirements, not preferences:

1. **Text sits on a surface opaque enough for at least 4.5:1 contrast.** Blur is decoration; it is
   never the only thing separating text from the backdrop.
2. **`prefers-reduced-transparency` and `prefers-reduced-motion` fall back to solid surfaces**
   with no blur, no aurora backdrop, and no motion. There is a matching
   `@supports not (backdrop-filter: ...)` fallback for browsers without the property.
3. **Status is never conveyed by colour alone** (WCAG 1.4.1). Every badge pairs colour with an
   icon and text. `Badge.test.tsx` enforces this.
4. The skip link and the 3px `:focus-visible` ring stay.
5. Toasts render in an `aria-live="polite"` region. Error toasts do not auto-dismiss.

## Components

| Component | Notes |
| --- | --- |
| `Icon` | 37 hand-authored inline SVGs, typed by name. Decorative by default; pass `title` when the icon is the only content of a control. |
| `Button`, `ButtonLink`, `ButtonAnchor` | `ButtonLink` is a router link. `ButtonAnchor` is a plain `<a>`, required for `/login` and `/logout`, which are full navigations to Flask. |
| `Badge`, `VmStatusBadge`, `PowerBadge`, `NetworkBadge`, `ActionBadge` | Blank values render an em dash instead of collapsing the cell. |
| `DataTable` | Client-side filter and sort over the rows currently on screen. Supply `value` for any column whose cell renders a badge or link, or it cannot be searched or sorted. |
| `Pagination` | Windowed: first, current ±2, last. `paginationWindow` is exported and unit tested. |
| `HistoryFilters` | Date/limit bar shared by the three history views. Ignore switches make inputs **read-only, not disabled**, so typed values survive and reappear when unticked. |
| `HistoryView` | Filter bar + table + pager. The three history pages differ only by their columns. |
| `ConfirmDialog` / `useConfirm` | Focus trap, Escape to cancel, restores focus on close. Names the specific resource. |
| `ToastProvider` / `useToast` | Replaces Flask flash messages. |

## Filters Live in the URL

The Jinja portal stored history filters in the Flask session and used POST-redirect-GET. Filters
are now query parameters, read by `useHistoryQuery` and by the BFF from `request.args`:
`startdate`, `enddate`, `limit`, `ignore_dates`, `ignore_limit`, `page`, `per_page`.

This makes a filtered view bookmarkable and shareable, stops two browser tabs from overwriting
each other's criteria, and keeps the session small. Dates are entered as `YYYY-MM-DD` and
converted to the `MM/DD/YYYY` the stored procedures expect; the ignore flags omit the filter
rather than sending the legacy `"null"` sentinel. `page` and `per_page` are clamped identically on
both sides (`per_page` caps at 200), so the client and the BFF never disagree.

## CSRF

`CSRFProtect` is enabled globally. The client reads the token from `/api/ui/session` and sends it
as an `X-CSRFToken` header on every `POST`; `Flask-WTF` accepts that header out of the box.
`lib/api.ts` attaches it automatically, so any request made through `apiPost` is covered. A `POST`
without it returns `400`. This is the easiest way to break a new endpoint.

## No CDN Policy

The portal must not make external asset requests at runtime. This is a hard requirement because
the solution supports Azure Government, sovereign, and air-gapped clouds where public CDNs are
unreachable.

- Everything is bundled by Vite and served from `static/dist/`.
- Fonts are the **system stack only**. Do not add a webfont.
- Icons are inline SVG. Do not add an icon font or an external sprite.
- Do not add a CDN `<link>` or `<script>` tag to `web/index.html`.

`test_the_shell_references_no_external_assets` guards the served shell.

**Build time is different from runtime.** The Node stage of the Dockerfile resolves packages from
the npm registry, so a fully disconnected build host needs an internal npm mirror. See
[deploy/DEPLOYMENT.md](../deploy/DEPLOYMENT.md).

## Running Locally

Two processes: Flask on `:5000` for auth and the BFF, and Vite on `:5173` for the SPA with
hot reload. Vite proxies `/api/ui`, `/login`, `/getAToken`, `/logout`, and `/health` to Flask, so
the sign-in flow behaves exactly as it does in production.

```powershell
cd .\front_end
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt -r requirements-dev.txt

$env:FLASK_KEY = "dev-secret"
$env:CLIENT_ID = "<frontend-app-client-id>"
$env:TENANT_ID = "<tenant-id>"
$env:MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = "<client-secret>"
$env:API_CLIENT_ID = "<broker-api-client-id>"
$env:API_URL = "https://<broker-api-host>/api"
$env:AZURE_CLOUD_NAME = "AzurePublic"
python .\app.py
```

In a second terminal:

```powershell
cd .\front_end\web
npm ci
npm run dev
```

Then open <http://localhost:5173>.

The app reads environment variables directly; it does not load `.env` files by itself. For Azure
US Government set `AZURE_CLOUD_NAME=AzureUSGovernment`. For custom or sovereign clouds without a
built-in profile set `AZURE_CLOUD_NAME=AzureCustom` and provide `AZURE_AUTHORITY_HOST`.

To run Flask alone against a production-style bundle, build first. Flask returns a plain-text
explanation instead of a blank page if the bundle is missing:

```powershell
cd .\front_end\web
npm run build     # writes ../static/dist
cd ..
python .\app.py   # now serves the SPA on :5000
```

The container image uses the same app with Gunicorn:

```powershell
gunicorn --bind 0.0.0.0:8000 app:app
```

## Building the Container Image

`Dockerfile` is multi-stage. A `node:22-alpine` stage runs `npm ci && npm run build`, and only
`static/dist/` is copied into the Python image, so the runtime image carries no Node toolchain and
the `web/` sources are removed. Nothing generated is committed; `package-lock.json` is, so `npm ci`
is reproducible.

## Testing

Two suites, both run in `.github/workflows/front-end-tests.yml`.

```powershell
# BFF contract
cd .\front_end
.\.venv\Scripts\Activate.ps1
python -m pytest

# Client
cd .\front_end\web
npm run typecheck
npm test
npm run build
```

`tests/conftest.py` fakes the Broker API with `FakeBrokerApi` and exposes three helpers worth
knowing: `csrf_token(client)` fetches a token the way the client does, `post(client, path, json)`
sends a `POST` with that header attached, and the `spa_bundle` fixture supplies a stand-in shell so
the SPA-serving tests do not depend on whether anyone has run `npm run build`. The Python suite
therefore needs no Node toolchain.

Behaviour is tested on whichever side now owns it. Broadly: date conversion, ignore-filter
semantics, pagination parameters, the legacy bare-list fallback, dashboard summary preference and
degradation, CSRF, and the error-status mapping are **pytest**; VM lifecycle rules, pagination
windowing, table sort and filter, the filter round-trip through the URL, badge accessibility,
confirm-dialog behaviour, theme persistence, and the error page are **Vitest**.

`web/src/App.test.tsx` is the integration layer: it mounts the real `App` with `fetch` stubbed and
walks every authenticated route, so a page that throws on mount, a missing provider, or a hook used
incorrectly fails there rather than in a browser. Add a row to its route table whenever you add a
page.

`tests/test_authorization.py` exercises every BFF business route with administrator, ordinary
workspace-user, scope-only, and ID-role-mismatch fixtures, plus expiry, subject mismatch,
capability outages, removed checkout paths, and required/stale lease guards. `FakeBrokerApi`
supplies the trusted `/me` contract; JWT verification itself belongs to the broker API suite.
The React tests cover pending/signed-out/denied/admin states, direct URLs, absence of unauthorized
queries/navigation, cache isolation (including late responses), and exact lease mutation bodies.

## How to Add a Page

1. Add the JSON endpoint to the matching `route_*.py` module, under `API_PREFIX`.
2. Decorate it with the administrator-enforcing `@login_required` and `@broker_endpoint("…")`. Use `json_body()` and
   `require()` for `POST` bodies so a missing field is named rather than becoming an opaque `400`.
3. Add the response shape to `web/src/types/broker.ts`.
4. Add a query or mutation hook to `web/src/hooks/useBroker.ts`. Gate queries with
   `useManagementAccess()`. Mutations should invalidate every query their change affects.
5. Create the page under `web/src/pages/`, and register it in the route table in `web/src/App.tsx`.
   Add a matching row to the route table in `web/src/App.test.tsx` so the page is mounted for real
   by the integration test.
6. Use `PageHeader` for the title and actions, `GlassCard` for panels, and `DataTable` for tables.
7. For a destructive action, use `useConfirm` so the operator sees the specific resource named.
8. Report the outcome with `useToast`, using the `error` string from the BFF on failure.
9. If the page belongs to a nav section, make sure its path is matched by `NAV_ITEMS` in
   `web/src/components/layout/NavBar.tsx`, or the active highlight will be wrong.

## What the Rewrite Changed

Worth knowing if you remember the Jinja portal:

- **No-JavaScript support is gone.** The old portal degraded to working HTML forms. A SPA cannot.
- **Flash messages are toasts.** Nothing is stored in the session between requests to render them.
- **History filters moved from the session to the URL**, as described above.
- **`route_user.py` is gone.** The profile page reads from `/api/ui/session`.
- **Bootstrap, `app.css`, `app.js`, and every Jinja template were deleted**, along with the
  `data-lb-*` attribute contract between them. The equivalents are typed component props now.
