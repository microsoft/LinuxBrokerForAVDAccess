# Service Management Portal Front End

This folder contains the Flask and Jinja **Service Management Portal** for the Linux Broker for AVD Access solution. It is the administrator UI for managing Linux host VMs, scaling rules, and broker activity by calling the Broker API. For the full solution context, see the repository [README](../README.md).

## Directory Layout

The front end is a small Flask app with server-rendered Jinja templates and local static assets.

| Path | Purpose |
| --- | --- |
| `app.py` | Creates the Flask app, enables global CSRF protection, registers route modules, and defines shared error handlers. |
| `config.py` | Reads cloud, Entra ID, and Broker API settings from environment variables. |
| `function_authentication.py` | Provides the `@login_required` decorator used by authenticated pages. |
| `function_api.py` | Centralises authenticated Broker API helpers, request timeouts, JSON decoding, dashboard VM summary retrieval, and paged history calls. |
| `route_authentication.py` | Implements sign in, token callback, and sign out. |
| `route_user.py` | Implements the profile page. |
| `route_vm_management.py` | Registers VM management routes with `register_route_vm_management(app)`. |
| `route_scaling_management.py` | Registers scaling and scaling-history routes with `register_route_scaling_management(app)`. |
| `templates\` | Shared layout, macro library, dashboard, error page, and feature templates. |
| `templates\vm\` | VM list, detail, form, checkout, and history templates. |
| `templates\scaling\` | Scaling rule, activity log, and rule history templates. |
| `static\css\app.css` | Portal design tokens and component classes layered on Bootstrap. |
| `static\js\app.js` | Progressive-enhancement behaviours for tables, confirmations, themes, forms, and filters. |
| `static\bootstrap\` | Vendored Bootstrap 5.3.8 CSS and JavaScript. |

Routes are registered from `app.py` by calling `register_route_*(app)` functions. Add new VM pages to the VM route module and new scaling pages to the scaling route module unless the page is genuinely cross-cutting.

Current Broker API data flow:

- The dashboard calls `GET /api/vms/summary` for aggregate counters. If that endpoint returns `404` or `405`, the portal falls back to `GET /api/vms` and counts client-side so rolling deployments keep working.
- VM history, scaling activity, and scaling rule history request one server-side page at a time with `page` and `per_page`. The Flask session stores only filter criteria, not full result sets, so result size is bounded and two browser tabs do not overwrite each other's data.
- The portal omits unset filters instead of sending the legacy `"null"` sentinel.

## Shared Macro Library

Import the shared macro library in every content template:

```jinja
{% extends "base.html" %}
{% import "_macros.html" as ui %}
```

The macros in `templates\_macros.html` keep status rendering, CSRF tokens, table controls, and destructive actions consistent.

| Macro | Signature | Usage |
| --- | --- | --- |
| `icon` | `icon(name, size=16, cls='')` | `{{ ui.icon('server', 20, 'text-body-secondary') }}` |
| `vm_status_badge` | `vm_status_badge(value)` | `{{ ui.vm_status_badge(vm.VmStatus) }}` |
| `power_badge` | `power_badge(value)` | `{{ ui.power_badge(vm.PowerState) }}` |
| `network_badge` | `network_badge(value)` | `{{ ui.network_badge(vm.NetworkStatus) }}` |
| `action_badge` | `action_badge(value)` | `{{ ui.action_badge(entry['ActionTaken']) }}` |
| `value_or_dash` | `value_or_dash(value)` | `{{ ui.value_or_dash(vm.Username) }}` |
| `page_header` | `page_header(title, subtitle='', icon_name='')` | Use with `{% call %}` when the header has action buttons. |
| `csrf_field` | `csrf_field()` | `{{ ui.csrf_field() }}` inside every POST form. |
| `empty_state` | `empty_state(title, message='', icon_name='list')` | `{{ ui.empty_state('No rules found', 'Create a rule first.', 'sliders') }}` |
| `pagination` | `pagination(endpoint, page, total_pages, per_page, window=2)` | `{{ ui.pagination('vm_history', page, total_pages, per_page) }}` |
| `per_page_select` | `per_page_select(endpoint, per_page, options=[10, 25, 50, 100])` | `{{ ui.per_page_select('vm_history', per_page) }}` |
| `table_toolbar` | `table_toolbar(target, placeholder='Search…', total=0, noun='rows')` | `{{ ui.table_toolbar('vms-table', 'Search VMs…', vms|length, 'VMs') }}` |
| `th_sort` | `th_sort(label, type='text', cls='')` | `{{ ui.th_sort('Created', 'date') }}` |
| `confirm_action` | `confirm_action(action_url, label, resource, variant='danger', icon_name='trash', title='', body='', size='sm', block=false, outline=true)` | Creates a POST form with CSRF and the shared confirmation modal. |

`page_header()` is a caller macro. Use `{% call %}` to pass header actions:

```jinja
{% call ui.page_header('Scaling Rules', 'Manage automatic VM capacity thresholds.', 'sliders') %}
  <a href="{{ url_for('create_rule') }}" class="btn btn-success btn-sm">
    {{ ui.icon('plus', 14) }}<span class="ms-1">Add rule</span>
  </a>
{% endcall %}
```

Use `confirm_action()` for destructive or state-changing table actions:

```jinja
{{ ui.confirm_action(
     url_for('delete_vm', vmid=vm.VMID),
     'Delete',
     vm.Hostname,
     title='Delete ' ~ vm.Hostname,
     body='Permanently delete ' ~ vm.Hostname ~ ' from the broker? This cannot be undone.') }}
```

Available `icon()` names are:

```text
activity, alert-triangle, arrow-down, arrow-return, arrow-up,
box-arrow-right, check-circle, chevron-down, chevron-expand,
chevron-left, chevron-right, chevron-up, clock, dash-circle, eye,
funnel, gauge, home, info-circle, list, moon, pencil, person, plus,
power, refresh, search, server, shield, sliders, sun, trash, wifi,
wifi-off, wrench, x, x-circle
```

Icons are hand-authored inline SVG. Do not add an icon font dependency; the inline SVGs keep the portal self-contained for disconnected, sovereign, and air-gapped environments.

Status must not be conveyed by colour alone. The badge macros always pair colour with an icon and text; follow the same pattern for any new status.

## `app.js` Data Hooks

`static\js\app.js` is progressive enhancement. The pages still render without JavaScript, but these hooks add client-side filtering, sorting, confirmation, form state, auto-refresh, and theme controls. Treat these names as API contracts between templates and JavaScript.

| Hook | Where it is used | Behaviour |
| --- | --- | --- |
| `data-lb-filter-target` | Search input generated by `ui.table_toolbar()` | Value is the target table `id`; typing filters the table body rows by text content. |
| `data-lb-filter-noun` | Search input generated by `ui.table_toolbar()` | Optional noun for the counter text; defaults to `rows`. |
| `data-lb-count-total` | Counter element generated by `ui.table_toolbar()` | Total row count used to show `N rows` or `shown of total rows`. |
| `data-lb-sort` with `th.lb-sortable` | Header generated by `ui.th_sort()` | Makes the column clickable and keyboard-sortable. Supported types are `text`, `number`, and `date`. |
| `data-lb-value` | Table cells | Overrides a cell's sort value, useful when the visible cell contains badge markup. |
| `data-lb-no-filter` | Table rows | Excludes rows, such as "no results" rows, from filtering and sorting. |
| `.lb-confirm-form` | Form generated by `ui.confirm_action()` | Intercepts submit and opens the shared Bootstrap confirmation modal. |
| `data-lb-confirm-title` | Confirm form and modal title element | Modal title text for the pending action. |
| `data-lb-confirm-body` | Confirm form and modal body element | Modal body text; also used by the native `confirm()` fallback. |
| `data-lb-confirm-label` | Confirm form | Confirm button text. |
| `data-lb-confirm-variant` | Confirm form | Bootstrap button variant for the confirm button. |
| `data-lb-confirm-ok` | Shared confirm modal button | Button that submits the pending form after confirmation. |
| `data-lb-no-guard` | Form | Opts a form out of the submit spinner and the double-submit guard. |
| `data-lb-disables` | Checkbox | Comma-separated input IDs to mark as ignored while the checkbox is checked. Inputs that support it are set `readonly` rather than `disabled`, so their values are still submitted and can be replayed into the form after the redirect. |
| `data-lb-autorefresh` | Checkbox or switch | Enables periodic `window.location.reload()`; the value is the interval in seconds. |
| `data-lb-autorefresh-status` | Label near auto-refresh switch | Receives `Off` or countdown text such as `in 30s`. |
| `data-lb-theme-toggle` | Theme toggle button | Toggles the Bootstrap theme and persists the choice. |

Example sortable/filterable table:

```jinja
{{ ui.table_toolbar('vms-table', 'Search hostname, IP, status or user…', vms|length, 'VMs') }}
<div class="lb-table-wrap">
  <table class="table lb-table table-hover" id="vms-table">
    <thead>
      <tr>
        {{ ui.th_sort('Hostname') }}
        {{ ui.th_sort('Status') }}
      </tr>
    </thead>
    <tbody>
      {% for vm in vms %}
      <tr>
        <td>{{ vm.Hostname }}</td>
        <td data-lb-value="{{ vm.VmStatus }}">{{ ui.vm_status_badge(vm.VmStatus) }}</td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
</div>
```

## Theming

Dark mode uses Bootstrap 5.3's native `data-bs-theme` attribute. `base.html` runs an inline script before first paint to set the stored or preferred theme and avoid a light/dark flash. The runtime toggle in `app.js` persists the user's choice in `localStorage` under `lb-theme`.

Express colours through Bootstrap CSS variables such as `--bs-body-bg`, `--bs-body-color`, `--bs-border-color`, and `--bs-secondary-color` so both themes work from one stylesheet. Portal-specific tokens live in `:root` in `static\css\app.css` and can be overridden under `[data-bs-theme="dark"]`.

## No CDN Policy

The portal must not make external asset requests. Bootstrap 5.3.8 is vendored under `static\bootstrap\` and loaded by `base.html`; the portal stylesheet, JavaScript, favicon, and icons are also served locally. This is a hard requirement because the solution supports Azure Government, sovereign, and air-gapped clouds where public CDNs are unreachable.

Do not add CDN `<link>` or `<script>` tags. That would break disconnected environments.

To upgrade Bootstrap:

1. Download the official `bootstrap-<version>-dist.zip` from Bootstrap.
2. Extract it outside the repo.
3. Replace `static\bootstrap\css\` with the zip's `css\` directory.
4. Replace `static\bootstrap\js\` with the zip's `js\` directory.
5. Verify `base.html` still points at `bootstrap/css/bootstrap.min.css` and `bootstrap/js/bootstrap.bundle.min.js`.
6. Run the portal locally and check both light and dark themes.

Do not document or depend on Bootstrap internals beyond the files the portal loads.

## CSRF

`Flask-WTF` `CSRFProtect` is enabled globally in `app.py`. Every POST form must include a CSRF token:

```jinja
<form method="POST" action="{{ url_for('create_rule') }}">
  {{ ui.csrf_field() }}
  ...
</form>
```

Forms generated by `ui.confirm_action()` already include the token. A POST form without a token returns `400` and is handled by the shared CSRF error handler. This is the easiest way to break a new page.

## How to Add a New Page

1. Add the route to the correct `route_*.py` module.
2. Decorate the view with `@login_required` unless the page must be public.
3. Use `function_api.py` helpers for new authenticated Broker API calls where practical.
4. Create a template under `templates\vm\` or `templates\scaling\`.
5. Start the template with:

   ```jinja
   {% extends "base.html" %}
   {% import "_macros.html" as ui %}
   ```

6. Use `ui.page_header()` for the page title and `{% call %}` for action buttons.
7. Wrap data tables in `.lb-card` and `.lb-table-wrap`, and use `.lb-table` on the table.
8. Use `ui.table_toolbar()`, `ui.th_sort()`, and `data-lb-value` when the table should filter or sort.
9. Add `{{ ui.csrf_field() }}` to every custom POST form, or use `ui.confirm_action()`.
10. If the endpoint belongs under VM Management or Scaling Management, add its Flask endpoint name to the `vm_endpoints` or `scaling_endpoints` list in `base.html`. Otherwise the active navigation highlight will be wrong.
11. Reuse `error.html` or flash messages for recoverable failures; do not create one-off error shells.

## Running Locally

Install and run from the `front_end` directory:

```powershell
cd .\front_end
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Set the required environment variables from `env.example`. The app reads environment variables directly; it does not load `.env` files by itself.

```powershell
$env:FLASK_KEY = "dev-secret"
$env:CLIENT_ID = "<frontend-app-client-id>"
$env:TENANT_ID = "<tenant-id>"
$env:MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = "<client-secret>"
$env:API_CLIENT_ID = "<broker-api-client-id>"
$env:API_URL = "https://<broker-api-host>/api"
$env:AZURE_CLOUD_NAME = "AzurePublic"
python .\app.py
```

For Azure US Government, set `AZURE_CLOUD_NAME=AzureUSGovernment`. For custom or sovereign clouds without a built-in profile, set `AZURE_CLOUD_NAME=AzureCustom` and provide `AZURE_AUTHORITY_HOST`.

The container image uses the same app with Gunicorn:

```powershell
gunicorn --bind 0.0.0.0:8000 app:app
```

## Error Handling

`error.html` is the shared error shell for the `400`, `403`, `404`, `500`, and CSRF handlers in `app.py`. It extends `base.html`, uses the shared icons, and provides a dashboard or sign-in path depending on session state. Keep new error paths on this template so the layout, theme, and navigation remain consistent.
