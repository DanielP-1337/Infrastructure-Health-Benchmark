(function (global) {
  'use strict';

  var DEFAULT_LOCALE = 'en-US';
  var STORAGE_KEY = 'InfrastructureHealth.Language';
  var COOKIE_NAME = 'InfrastructureHealth.Language';
  var SUPPORTED = [
    { code: 'en-US', label: 'English (US)' },
    { code: 'de-DE', label: 'Deutsch' },
    { code: 'es-ES', label: 'Español' },
    { code: 'fr-FR', label: 'Français' },
    { code: 'it-IT', label: 'Italiano' },
    { code: 'nl-NL', label: 'Nederlands' },
    { code: 'pl-PL', label: 'Polski' },
    { code: 'sv-SE', label: 'Svenska' }
  ];

  var english = {};
  var active = {};
  var locale = DEFAULT_LOCALE;
  var tooltipElement = null;
  var tooltipTarget = null;

  function supported(code) {
    return SUPPORTED.some(function (item) { return item.code === code; });
  }

  function readCookie() {
    var prefix = COOKIE_NAME + '=';
    var parts = document.cookie ? document.cookie.split(';') : [];
    for (var i = 0; i < parts.length; i++) {
      var value = parts[i].trim();
      if (value.indexOf(prefix) === 0) return decodeURIComponent(value.substring(prefix.length));
    }
    return null;
  }

  function storedLocale() {
    var value = null;
    try { value = global.localStorage.getItem(STORAGE_KEY); } catch (e) { value = null; }
    if (!value) value = readCookie();
    return supported(value) ? value : DEFAULT_LOCALE;
  }

  function persistLocale(code) {
    try { global.localStorage.setItem(STORAGE_KEY, code); } catch (e) { /* cookie remains fallback */ }
    document.cookie = COOKIE_NAME + '=' + encodeURIComponent(code) + '; Max-Age=34560000; Path=/; SameSite=Lax';
  }

  function bust(url) {
    return url + (url.indexOf('?') >= 0 ? '&' : '?') + 'vlhi18n=' + Date.now();
  }

  async function loadFile(code) {
    var response = await fetch(bust('i18n/' + code + '.json'), {
      cache: 'no-store',
      credentials: 'same-origin'
    });
    if (!response.ok) throw new Error('HTTP ' + response.status + ' loading locale ' + code);
    return response.json();
  }

  function interpolate(text, params) {
    if (!params) return text;
    return text.replace(/\{([A-Za-z0-9_]+)\}/g, function (all, name) {
      return Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : all;
    });
  }

  function t(key, params) {
    var value = Object.prototype.hasOwnProperty.call(active, key) ? active[key] : english[key];
    if (value == null) value = key;
    return interpolate(String(value), params);
  }

  function queryIncludingRoot(root, selector) {
    var items = [];
    if (root && root.nodeType === 1 && root.matches && root.matches(selector)) items.push(root);
    if (root && root.querySelectorAll) {
      Array.prototype.push.apply(items, root.querySelectorAll(selector));
    }
    return items;
  }

  function apply(root) {
    root = root || document;
    var textNodes = queryIncludingRoot(root, '[data-i18n]');
    Array.prototype.forEach.call(textNodes, function (el) {
      el.textContent = t(el.getAttribute('data-i18n'));
    });
    var titleNodes = queryIncludingRoot(root, '[data-i18n-title]');
    Array.prototype.forEach.call(titleNodes, function (el) {
      el.setAttribute('title', t(el.getAttribute('data-i18n-title')));
    });
    var ariaNodes = queryIncludingRoot(root, '[data-i18n-aria]');
    Array.prototype.forEach.call(ariaNodes, function (el) {
      el.setAttribute('aria-label', t(el.getAttribute('data-i18n-aria')));
    });
    var tooltipNodes = queryIncludingRoot(root, '[data-i18n-tooltip]');
    Array.prototype.forEach.call(tooltipNodes, function (el) {
      el.setAttribute('data-tooltip-text', t(el.getAttribute('data-i18n-tooltip')));
    });
    document.documentElement.lang = locale;
    document.title = t('app.title');
    if (tooltipTarget && tooltipElement && !tooltipElement.classList.contains('hidden')) {
      tooltipElement.textContent = tooltipTarget.getAttribute('data-tooltip-text') || '';
      positionTooltip(tooltipTarget);
    }
  }

  function closestTooltipTarget(node) {
    if (!node || node.nodeType !== 1 || !node.closest) return null;
    return node.closest('[data-tooltip-text]');
  }

  function positionTooltip(target) {
    if (!tooltipElement || !target || tooltipElement.classList.contains('hidden')) return;
    var rect = target.getBoundingClientRect();
    var tipRect = tooltipElement.getBoundingClientRect();
    var margin = 10;
    var left = rect.left + (rect.width / 2) - (tipRect.width / 2);
    left = Math.max(12, Math.min(left, global.innerWidth - tipRect.width - 12));
    var top = rect.top - tipRect.height - margin;
    var placement = 'top';
    if (top < 12) {
      top = rect.bottom + margin;
      placement = 'bottom';
    }
    if (top + tipRect.height > global.innerHeight - 12) {
      top = Math.max(12, global.innerHeight - tipRect.height - 12);
    }
    tooltipElement.style.left = Math.round(left) + 'px';
    tooltipElement.style.top = Math.round(top) + 'px';
    tooltipElement.setAttribute('data-placement', placement);
  }

  function showTooltip(target) {
    if (!tooltipElement || !target) return;
    var text = target.getAttribute('data-tooltip-text');
    if (!text) return;
    tooltipTarget = target;
    tooltipElement.textContent = text;
    tooltipElement.classList.remove('hidden');
    tooltipElement.setAttribute('aria-hidden', 'false');
    target.setAttribute('aria-describedby', 'vlhTooltip');
    positionTooltip(target);
  }

  function hideTooltip(target) {
    if (!tooltipElement) return;
    if (target && tooltipTarget && target !== tooltipTarget) return;
    if (tooltipTarget) tooltipTarget.removeAttribute('aria-describedby');
    tooltipTarget = null;
    tooltipElement.classList.add('hidden');
    tooltipElement.setAttribute('aria-hidden', 'true');
  }

  function initTooltips() {
    tooltipElement = document.getElementById('vlhTooltip');
    if (!tooltipElement || tooltipElement.__vlhBound) return;
    tooltipElement.__vlhBound = true;

    document.addEventListener('mouseover', function (event) {
      var target = closestTooltipTarget(event.target);
      if (target) showTooltip(target);
    }, true);
    document.addEventListener('mouseout', function (event) {
      var target = closestTooltipTarget(event.target);
      if (!target) return;
      var next = event.relatedTarget && closestTooltipTarget(event.relatedTarget);
      if (next === target) return;
      hideTooltip(target);
    }, true);
    document.addEventListener('focusin', function (event) {
      var target = closestTooltipTarget(event.target);
      if (target) showTooltip(target);
    }, true);
    document.addEventListener('focusout', function (event) {
      var target = closestTooltipTarget(event.target);
      if (target) hideTooltip(target);
    }, true);
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape') hideTooltip();
    });
    global.addEventListener('scroll', function () { hideTooltip(); }, true);
    global.addEventListener('resize', function () { hideTooltip(); });
  }

  function populateSelector() {
    var select = document.getElementById('languageSelect');
    if (!select) return;
    select.innerHTML = '';
    SUPPORTED.forEach(function (item) {
      var option = document.createElement('option');
      option.value = item.code;
      option.textContent = item.label;
      select.appendChild(option);
    });
    select.value = locale;
    select.setAttribute('aria-label', t('language.aria'));
    if (!select.__vlhI18nBound) {
      select.addEventListener('change', function () {
        setLocale(select.value, true);
      });
      select.__vlhI18nBound = true;
    }
  }

  async function setLocale(code, persist) {
    if (!supported(code)) code = DEFAULT_LOCALE;
    var selected = code;
    try {
      if (!Object.keys(english).length) english = await loadFile(DEFAULT_LOCALE);
      active = selected === DEFAULT_LOCALE ? english : await loadFile(selected);
      locale = selected;
    } catch (e) {
      active = english;
      locale = DEFAULT_LOCALE;
      selected = DEFAULT_LOCALE;
    }
    if (persist) persistLocale(selected);
    apply(document);
    populateSelector();
    global.dispatchEvent(new CustomEvent('infrastructure-language-changed', { detail: { locale: locale } }));
    return locale;
  }

  async function init() {
    initTooltips();
    english = await loadFile(DEFAULT_LOCALE);
    active = english;
    return setLocale(storedLocale(), false);
  }

  global.IHBI18n = {
    init: init,
    setLocale: setLocale,
    t: t,
    apply: apply,
    getLocale: function () { return locale; },
    getSupported: function () { return SUPPORTED.slice(); },
    defaultLocale: DEFAULT_LOCALE,
    hideTooltip: hideTooltip
  };
})(window);
