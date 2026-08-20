/* ==========================================================================
   Linux Broker Management Portal — progressive enhancement.
   Plain ES5-compatible browser JS. No build step, no runtime dependencies
   beyond the vendored Bootstrap bundle.
   ========================================================================== */

(function () {
  'use strict';

  var THEME_KEY = 'lb-theme';
  var REFRESH_KEY = 'lb-autorefresh';

  /* ---------------------------------------------------------------- theme */

  function currentTheme() {
    return document.documentElement.getAttribute('data-bs-theme') === 'dark' ? 'dark' : 'light';
  }

  function applyTheme(theme) {
    document.documentElement.setAttribute('data-bs-theme', theme);
    try { localStorage.setItem(THEME_KEY, theme); } catch (e) { /* private mode */ }
    var btn = document.querySelector('[data-lb-theme-toggle]');
    if (btn) {
      var next = theme === 'dark' ? 'light' : 'dark';
      btn.setAttribute('aria-label', 'Switch to ' + next + ' theme');
      btn.setAttribute('title', 'Switch to ' + next + ' theme');
    }
  }

  function initTheme() {
    applyTheme(currentTheme());
    var btn = document.querySelector('[data-lb-theme-toggle]');
    if (!btn) return;
    btn.addEventListener('click', function () {
      applyTheme(currentTheme() === 'dark' ? 'light' : 'dark');
    });
  }

  /* -------------------------------------------------------- table filter */

  function initTableFilter() {
    var inputs = document.querySelectorAll('[data-lb-filter-target]');

    Array.prototype.forEach.call(inputs, function (input) {
      var table = document.getElementById(input.getAttribute('data-lb-filter-target'));
      if (!table) return;

      var counter = document.getElementById(table.id + '-count');
      var noun = input.getAttribute('data-lb-filter-noun') || 'rows';

      function apply() {
        var q = input.value.trim().toLowerCase();
        var rows = table.tBodies.length ? table.tBodies[0].rows : [];
        var shown = 0;

        for (var i = 0; i < rows.length; i++) {
          var row = rows[i];
          if (row.hasAttribute('data-lb-no-filter')) continue;
          var match = !q || (row.textContent || '').toLowerCase().indexOf(q) !== -1;
          row.classList.toggle('lb-hidden', !match);
          if (match) shown++;
        }

        if (counter) {
          var total = parseInt(counter.getAttribute('data-lb-count-total'), 10) || 0;
          counter.textContent = q
            ? shown + ' of ' + total + ' ' + noun
            : total + ' ' + noun;
        }

        var empty = document.getElementById(table.id + '-noresults');
        if (empty) empty.classList.toggle('d-none', shown !== 0);
      }

      input.addEventListener('input', apply);
      input.addEventListener('search', apply);
      apply();
    });
  }

  /* ---------------------------------------------------------- table sort */

  function cellValue(row, index) {
    var cell = row.cells[index];
    if (!cell) return '';
    var explicit = cell.getAttribute('data-lb-value');
    return (explicit !== null ? explicit : cell.textContent || '').trim();
  }

  function comparator(index, type, dir) {
    return function (a, b) {
      var av = cellValue(a, index);
      var bv = cellValue(b, index);

      if (type === 'number') {
        var an = parseFloat(av.replace(/[^0-9.eE+-]/g, ''));
        var bn = parseFloat(bv.replace(/[^0-9.eE+-]/g, ''));
        var aNaN = isNaN(an);
        var bNaN = isNaN(bn);
        if (aNaN && bNaN) return 0;
        if (aNaN) return 1;          // blanks always sort last
        if (bNaN) return -1;
        return (an - bn) * dir;
      }

      if (type === 'date') {
        var ad = Date.parse(av);
        var bd = Date.parse(bv);
        var adNaN = isNaN(ad);
        var bdNaN = isNaN(bd);
        if (adNaN && bdNaN) return 0;
        if (adNaN) return 1;
        if (bdNaN) return -1;
        return (ad - bd) * dir;
      }

      if (!av && !bv) return 0;
      if (!av) return 1;
      if (!bv) return -1;
      return av.localeCompare(bv, undefined, { numeric: true, sensitivity: 'base' }) * dir;
    };
  }

  function initTableSort() {
    var headers = document.querySelectorAll('th.lb-sortable');

    Array.prototype.forEach.call(headers, function (th) {
      function sort() {
        var table = th.closest('table');
        if (!table || !table.tBodies.length) return;

        var body = table.tBodies[0];
        var index = Array.prototype.indexOf.call(th.parentNode.cells, th);
        var type = th.getAttribute('data-lb-sort') || 'text';
        var asc = th.getAttribute('aria-sort') !== 'ascending';

        Array.prototype.forEach.call(table.querySelectorAll('th.lb-sortable'), function (other) {
          other.setAttribute('aria-sort', 'none');
        });
        th.setAttribute('aria-sort', asc ? 'ascending' : 'descending');

        var rows = Array.prototype.filter.call(body.rows, function (r) {
          return !r.hasAttribute('data-lb-no-filter');
        });
        rows.sort(comparator(index, type, asc ? 1 : -1));
        rows.forEach(function (r) { body.appendChild(r); });
      }

      th.addEventListener('click', sort);
      th.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar') {
          e.preventDefault();
          sort();
        }
      });
    });
  }

  /* ------------------------------------------------------- confirm modal */

  /*
   * Replaces the generic native confirm('Are you sure you want to delete this
   * VM?') with a modal that names the specific host being acted on.
   */
  function initConfirm() {
    var forms = document.querySelectorAll('.lb-confirm-form');
    if (!forms.length) return;

    var modalEl = document.getElementById('lb-confirm-modal');
    var pending = null;

    // No modal markup or no Bootstrap JS: fall back to a descriptive confirm().
    if (!modalEl || !window.bootstrap || !window.bootstrap.Modal) {
      Array.prototype.forEach.call(forms, function (form) {
        form.addEventListener('submit', function (e) {
          var body = form.getAttribute('data-lb-confirm-body') || 'Are you sure?';
          if (!window.confirm(body)) e.preventDefault();
        });
      });
      return;
    }

    var modal = new window.bootstrap.Modal(modalEl);
    var titleEl = modalEl.querySelector('[data-lb-confirm-title]');
    var bodyEl = modalEl.querySelector('[data-lb-confirm-body]');
    var okBtn = modalEl.querySelector('[data-lb-confirm-ok]');
    var opener = null;
    var shouldReturnFocus = false;

    Array.prototype.forEach.call(forms, function (form) {
      form.addEventListener('submit', function (e) {
        if (form.dataset.lbConfirmed === 'true') return;   // second, real submit
        e.preventDefault();

        pending = form;
        opener = e.submitter || form.querySelector('button[type="submit"], input[type="submit"]');
        shouldReturnFocus = true;
        if (titleEl) titleEl.textContent = form.getAttribute('data-lb-confirm-title') || 'Confirm';
        if (bodyEl) bodyEl.textContent = form.getAttribute('data-lb-confirm-body') || 'Are you sure?';

        if (okBtn) {
          okBtn.textContent = form.getAttribute('data-lb-confirm-label') || 'Confirm';
          okBtn.className = 'btn btn-' + (form.getAttribute('data-lb-confirm-variant') || 'danger');
        }
        modal.show();
      });
    });

    if (okBtn) {
      okBtn.addEventListener('click', function () {
        if (!pending) return;
        shouldReturnFocus = false;
        pending.dataset.lbConfirmed = 'true';
        modal.hide();
        if (typeof pending.requestSubmit === 'function') {
          pending.requestSubmit();
        } else {
          pending.submit();
        }
        pending = null;
      });
    }

    modalEl.addEventListener('shown.bs.modal', function () {
      if (okBtn && typeof okBtn.focus === 'function') okBtn.focus();
    });

    modalEl.addEventListener('hidden.bs.modal', function () {
      var returnTarget = opener;
      pending = null;
      opener = null;
      if (shouldReturnFocus && returnTarget && document.contains(returnTarget) &&
          typeof returnTarget.focus === 'function') {
        returnTarget.focus();
      }
      shouldReturnFocus = false;
    });
  }

  /* ------------------------------------------------- submit pending state */

  function initSubmitGuard() {
    document.addEventListener('submit', function (e) {
      var form = e.target;
      if (!(form instanceof HTMLFormElement)) return;
      if (form.hasAttribute('data-lb-no-guard')) return;
      if (form.classList.contains('lb-confirm-form') && form.dataset.lbConfirmed !== 'true') return;
      if (typeof form.checkValidity === 'function' && !form.checkValidity()) return;

      var btn = form.querySelector('button[type="submit"], input[type="submit"]');
      if (!btn || btn.classList.contains('is-loading')) return;

      btn.classList.add('is-loading');
      btn.setAttribute('aria-busy', 'true');
      if (btn.tagName === 'BUTTON' && !btn.querySelector('.lb-spinner')) {
        btn.insertBefore(document.createElement('span'), btn.firstChild).className = 'lb-spinner';
      }

      // Re-enable if the browser restores the page from bfcache.
      window.setTimeout(function () {
        btn.classList.remove('is-loading');
        btn.removeAttribute('aria-busy');
      }, 15000);
    }, true);
  }

  /* ----------------------------------------------- client-side validation */

  function initValidation() {
    var forms = document.querySelectorAll('.needs-validation');
    Array.prototype.forEach.call(forms, function (form) {
      form.addEventListener('submit', function (e) {
        if (!form.checkValidity()) {
          e.preventDefault();
          e.stopPropagation();
          var first = form.querySelector(':invalid');
          if (first && typeof first.focus === 'function') first.focus();
        }
        form.classList.add('was-validated');
      }, false);
    });
  }

  /* ------------------------------------------------------- auto refresh */

  function initAutoRefresh() {
    var toggle = document.querySelector('[data-lb-autorefresh]');
    if (!toggle) return;

    var seconds = parseInt(toggle.getAttribute('data-lb-autorefresh'), 10) || 30;
    var timer = null;
    var label = document.querySelector('[data-lb-autorefresh-status]');

    function stop() {
      if (timer) { window.clearInterval(timer); timer = null; }
      if (label) label.textContent = 'Off';
    }

    function start() {
      stop();
      var remaining = seconds;
      if (label) label.textContent = 'in ' + remaining + 's';
      timer = window.setInterval(function () {
        remaining -= 1;
        if (label) label.textContent = 'in ' + remaining + 's';
        if (remaining <= 0) window.location.reload();
      }, 1000);
    }

    toggle.addEventListener('change', function () {
      try { localStorage.setItem(REFRESH_KEY, toggle.checked ? '1' : '0'); } catch (e) { /* noop */ }
      if (toggle.checked) { start(); } else { stop(); }
    });

    var stored = null;
    try { stored = localStorage.getItem(REFRESH_KEY); } catch (e) { /* noop */ }
    if (stored === '1') { toggle.checked = true; start(); } else { stop(); }
  }

  /* ------------------------------------------------------- filter bar UX */

  /* "Ignore dates" / "No limit" disable the inputs they override, so the form
     visibly reflects what will actually be sent. */
  function initFilterToggles() {
    // Input types that still submit their value while readOnly.
    var SUBMITTABLE_READONLY = /^(?:text|search|url|tel|email|password|number|date|month|week|time|datetime-local)$/i;

    Array.prototype.forEach.call(document.querySelectorAll('[data-lb-disables]'), function (cb) {
      var ids = (cb.getAttribute('data-lb-disables') || '').split(',');
      var label = cb.id ? document.querySelector('label[for="' + cb.id + '"]') : null;
      var controllerName = label ? label.textContent.replace(/\s+/g, ' ').trim() : 'this filter';

      function appendToken(value, token) {
        var parts = (value || '').split(/\s+/).filter(Boolean);
        if (parts.indexOf(token) === -1) parts.push(token);
        return parts.join(' ');
      }

      function removeToken(value, token) {
        return (value || '').split(/\s+/).filter(function (part) {
          return part && part !== token;
        }).join(' ');
      }

      if (cb.id && !document.getElementById(cb.id + '-description')) {
        var cbDesc = document.createElement('span');
        cbDesc.id = cb.id + '-description';
        cbDesc.className = 'visually-hidden';
        cbDesc.textContent = 'When selected, ignores ' + ids.map(function (id) {
          var el = document.getElementById(id.trim());
          var elLabel = el && el.id ? document.querySelector('label[for="' + el.id + '"]') : null;
          return elLabel ? elLabel.textContent.replace(/\s+/g, ' ').trim() : id.trim();
        }).join(', ') + '.';
        cb.parentNode.appendChild(cbDesc);
        cb.setAttribute('aria-describedby', appendToken(cb.getAttribute('aria-describedby'), cbDesc.id));
      }

      function sync() {
        ids.forEach(function (id) {
          var el = document.getElementById(id.trim());
          if (!el) return;
          var noteId = el.id + '-disabled-note';
          var note = document.getElementById(noteId);
          if (!note) {
            note = document.createElement('div');
            note.id = noteId;
            note.className = 'form-text lb-disabled-note';
            note.textContent = 'Ignored while ' + controllerName + ' is selected.';
            var field = el.closest('.lb-field');
            (field || el.parentNode).appendChild(note);
          }
          // Use readOnly rather than disabled where the control supports it:
          // disabled controls are omitted from form submission, which silently
          // discarded whatever the operator had typed, so the value could not be
          // replayed into the filter bar after the POST/redirect/GET round trip.
          if (SUBMITTABLE_READONLY.test(el.type || '')) {
            el.readOnly = cb.checked;
          } else {
            el.disabled = cb.checked;
          }
          el.setAttribute('aria-disabled', cb.checked ? 'true' : 'false');
          if (cb.checked) {
            el.setAttribute('aria-describedby', appendToken(el.getAttribute('aria-describedby'), noteId));
          } else {
            var describedBy = removeToken(el.getAttribute('aria-describedby'), noteId);
            if (describedBy) el.setAttribute('aria-describedby', describedBy);
            else el.removeAttribute('aria-describedby');
          }
          var group = el.closest('.lb-field');
          if (group) group.classList.toggle('lb-field-disabled', cb.checked);
        });
      }

      cb.addEventListener('change', sync);
      sync();
    });
  }

  /* ----------------------------------------------------------------- init */

  function init() {
    initTheme();
    initTableFilter();
    initTableSort();
    initConfirm();
    initSubmitGuard();
    initValidation();
    initAutoRefresh();
    initFilterToggles();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
