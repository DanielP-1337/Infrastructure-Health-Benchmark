(function (global) {
  'use strict';

  function bust(url) {
    return url + (url.indexOf('?') >= 0 ? '&' : '?') + 'vlh=' + Date.now() + '-' + Math.random().toString(16).slice(2);
  }

  function joinUrl(base, relative) {
    return String(base || '').replace(/\/$/, '') + '/' + String(relative || '').replace(/^\//, '');
  }

  async function fetchMeasure(url) {
    var start = performance.now();
    var response = await fetch(bust(url), { cache: 'no-store', credentials: 'same-origin' });
    var headersAt = performance.now();
    if (!response.ok) throw new Error('HTTP ' + response.status + ' for ' + url);
    var bytes = 0;
    if (response.body && response.body.getReader) {
      var reader = response.body.getReader();
      while (true) {
        var part = await reader.read();
        if (part.done) break;
        bytes += part.value.byteLength;
      }
    } else {
      var buffer = await response.arrayBuffer();
      bytes = buffer.byteLength;
    }
    var end = performance.now();
    var seconds = Math.max((end - start) / 1000, 0.001);
    return {
      url: url,
      bytes: bytes,
      ttfbMs: headersAt - start,
      totalMs: end - start,
      mbps: (bytes * 8 / 1000000) / seconds
    };
  }

  async function parallelFetch(urls, concurrency) {
    var index = 0;
    var results = [];
    var errors = [];
    async function worker() {
      while (true) {
        var i = index++;
        if (i >= urls.length) return;
        var started = performance.now();
        try {
          var r = await fetchMeasure(urls[i]);
          r.requestMs = performance.now() - started;
          results.push(r);
        } catch (e) {
          errors.push({ url: urls[i], error: String(e) });
        }
      }
    }
    var workers = [];
    for (var w = 0; w < Math.min(concurrency, urls.length); w++) workers.push(worker());
    var allStart = performance.now();
    await Promise.all(workers);
    var allMs = performance.now() - allStart;
    return { results: results, errors: errors, totalMs: allMs };
  }

  function percentile(values, p) {
    if (!values.length) return null;
    var sorted = values.slice().sort(function (a,b) { return a-b; });
    var idx = Math.ceil((p / 100) * sorted.length) - 1;
    return sorted[Math.max(0, Math.min(sorted.length - 1, idx))];
  }

  function tileUrls(baseUrl) {
    var urls = [];
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        urls.push(baseUrl.replace(/\/$/, '') + '/benchmark_files/10/' + x + '_' + y + '.png');
      }
    }
    return urls;
  }

  async function quick(basePath, imageBaseUrl) {
    var one = await fetchMeasure(basePath + 'data/1MB.bin');
    var tiles = null;
    if (imageBaseUrl) {
      var sample = tileUrls(imageBaseUrl).slice(0, 4);
      tiles = await parallelFetch(sample, 4);
    }
    return {
      mode: 'quick',
      serial: [one],
      parallel: null,
      tiles: summarizeTiles(tiles),
      workload: { id: 'synthetic-quick', kind: 'synthetic-dzi', reference: false }
    };
  }

  async function loadWorkloadDefinitions(basePath) {
    var response = await fetch(bust(basePath + 'workloads/templates.json'), { cache: 'no-store', credentials: 'same-origin' });
    if (!response.ok) throw new Error('HTTP ' + response.status + ' loading workload templates');
    return response.json();
  }

  function normalizeReferenceCatalog(catalog) {
    if (!catalog || !catalog.templates) return catalog;
    var aliases = { vivablock: 'xy-mosaic', vivastack: 'z-stack', vivacube: 'volume' };
    Object.keys(aliases).forEach(function (oldId) {
      var id = aliases[oldId];
      if (catalog.templates[oldId]) {
        if (catalog.templates[id]) throw new Error('Ambiguous reference workload: ' + id);
        catalog.templates[id] = catalog.templates[oldId];
        delete catalog.templates[oldId];
      }
    });
    if (catalog.enabledTemplates) catalog.enabledTemplates = catalog.enabledTemplates.map(function (id) { return aliases[id] || id; });
    if (catalog.profile === 'VS3000') catalog.profile = 'SingleField';
    // Preserve payload URLs: legacy folders are still valid local datasets.
    return catalog;
  }

  async function loadReferenceCatalog(imageBaseUrl) {
    if (!imageBaseUrl) return null;
    try {
      var response = await fetch(bust(joinUrl(imageBaseUrl, 'reference/reference.json')), { cache: 'no-store', credentials: 'same-origin' });
      if (!response.ok) return null;
      return normalizeReferenceCatalog(await response.json());
    } catch (e) {
      return null;
    }
  }

  function findTemplate(definitions, id) {
    if (!definitions || !definitions.templates) return null;
    for (var i = 0; i < definitions.templates.length; i++) {
      if (definitions.templates[i].id === id) return definitions.templates[i];
    }
    return null;
  }

  function createDziTileSource(source, imageBaseUrl, runToken) {
    var tileBase = joinUrl(imageBaseUrl, source.tileBaseUrl);
    return {
      width: Number(source.width),
      height: Number(source.height),
      tileSize: Number(source.tileSize || 256),
      tileOverlap: Number(source.overlap || 0),
      minLevel: Number(source.minLevel || 0),
      maxLevel: Number(source.maxLevel),
      getTileUrl: function (level, x, y) {
        return tileBase + '/' + level + '/' + x + '_' + y + '.' + source.format + '?vlhref=' + runToken;
      }
    };
  }

  function resourceEntriesForToken(runToken) {
    return performance.getEntriesByType('resource').filter(function (entry) {
      return entry.name.indexOf('vlhref=' + runToken) >= 0;
    });
  }

  function summarizeResourceEntries(entries) {
    var durations = entries.map(function (entry) { return Number(entry.duration || 0); }).filter(function (v) { return isFinite(v); });
    var bytes = entries.reduce(function (sum, entry) {
      var value = Number(entry.encodedBodySize || entry.transferSize || 0);
      return sum + (isFinite(value) ? value : 0);
    }, 0);
    return {
      requests: entries.length,
      failures: 0,
      p50Ms: percentile(durations, 50),
      p95Ms: percentile(durations, 95),
      p99Ms: percentile(durations, 99),
      bytes: bytes
    };
  }

  function waitForOpen(viewer, timeoutMs) {
    return new Promise(function (resolve, reject) {
      var done = false;
      var timer = setTimeout(function () {
        if (done) return;
        done = true;
        reject(new Error('OpenSeadragon open timeout'));
      }, timeoutMs || 10000);
      viewer.addOnceHandler('open', function () {
        if (done) return;
        done = true;
        clearTimeout(timer);
        resolve();
      });
      viewer.addOnceHandler('open-failed', function (event) {
        if (done) return;
        done = true;
        clearTimeout(timer);
        reject(new Error((event && event.message) || 'OpenSeadragon open failed'));
      });
    });
  }

  function waitForViewportSettled(viewer, tiledImage, settleMs, timeoutMs) {
    return new Promise(function (resolve) {
      var started = performance.now();
      var stableSince = performance.now();
      var lastCount = -1;
      var timer = setInterval(function () {
        var count = viewer.world && viewer.world.getItemCount ? viewer.world.getItemCount() : 0;
        var fullyLoaded = true;
        try {
          if (tiledImage && typeof tiledImage.getFullyLoaded === 'function') fullyLoaded = tiledImage.getFullyLoaded();
        } catch (e) { fullyLoaded = true; }
        var animating = false;
        try { animating = !!viewer.viewport.getAnimating(); } catch (e2) { animating = false; }

        if (count !== lastCount || animating || !fullyLoaded) {
          stableSince = performance.now();
          lastCount = count;
        }

        var elapsed = performance.now() - started;
        if ((!animating && fullyLoaded && (performance.now() - stableSince) >= settleMs) || elapsed >= timeoutMs) {
          clearInterval(timer);
          resolve({ timedOut: elapsed >= timeoutMs, elapsedMs: elapsed });
        }
      }, 75);
    });
  }

  async function navigateSource(viewer, source, template, imageBaseUrl, runToken, phasePrefix) {
    var tileSource = createDziTileSource(source, imageBaseUrl, runToken);
    var openPromise = waitForOpen(viewer, template.stepTimeoutMs || 12000);
    viewer.open(tileSource);
    await openPromise;

    var tiledImage = viewer.world.getItemAt(0);
    var steps = [];
    var allStart = performance.now();
    var lastResourceCount = resourceEntriesForToken(runToken).length;

    for (var i = 0; i < template.steps.length; i++) {
      var step = template.steps[i];
      var stepStart = performance.now();
      var center = tiledImage.imageToViewportCoordinates(
        Number(source.width) * Number(step.centerX),
        Number(source.height) * Number(step.centerY)
      );
      var zoom = tiledImage.imageToViewportZoom(Number(step.imageZoom));
      viewer.viewport.panTo(center, true);
      viewer.viewport.zoomTo(zoom, center, true);
      viewer.viewport.applyConstraints(true);
      var settle = await waitForViewportSettled(viewer, tiledImage, Number(template.settleMs || 250), Number(template.stepTimeoutMs || 12000));
      var current = resourceEntriesForToken(runToken);
      var newEntries = current.slice(lastResourceCount);
      lastResourceCount = current.length;
      var summary = summarizeResourceEntries(newEntries);
      steps.push({
        id: (phasePrefix ? phasePrefix + ':' : '') + step.id,
        elapsedMs: performance.now() - stepStart,
        timedOut: settle.timedOut,
        requests: summary.requests,
        bytes: summary.bytes,
        p50Ms: summary.p50Ms,
        p95Ms: summary.p95Ms,
        p99Ms: summary.p99Ms
      });
    }

    return { elapsedMs: performance.now() - allStart, steps: steps };
  }

  async function runDziWorkload(template, catalogEntry, imageBaseUrl, viewerElementId) {
    if (!global.OpenSeadragon) throw new Error('Bundled OpenSeadragon is unavailable.');
    var viewerElement = document.getElementById(viewerElementId);
    if (!viewerElement) throw new Error('OpenSeadragon benchmark viewer element not found.');

    viewerElement.innerHTML = '';
    performance.clearResourceTimings();
    var runToken = Date.now() + '-' + Math.random().toString(16).slice(2);
    var failures = [];
    var viewer = OpenSeadragon({
      id: viewerElementId,
      showNavigationControl: false,
      showNavigator: false,
      animationTime: 0.15,
      blendTime: 0,
      immediateRender: true,
      maxImageCacheCount: 512
    });
    viewer.addHandler('tile-load-failed', function (event) {
      failures.push({ message: (event && event.message) || 'Tile load failed' });
    });

    var started = performance.now();
    var phases = [];
    var sources = catalogEntry.sources || [];
    if (!sources.length) throw new Error('Reference DZI source is missing.');

    if (template.kind === 'dzi-navigation') {
      phases.push(await navigateSource(viewer, sources[0], template, imageBaseUrl, runToken, sources[0].name || 'block1'));
    } else {
      for (var s = 0; s < sources.length; s++) {
        phases.push(await navigateSource(viewer, sources[s], template, imageBaseUrl, runToken, sources[s].name || ('plane' + (s + 1))));
      }
    }

    var entries = resourceEntriesForToken(runToken);
    var summary = summarizeResourceEntries(entries);
    summary.failures = failures.length;
    summary.totalMs = performance.now() - started;
    summary.errors = failures;
    summary.phases = phases;
    summary.reference = true;
    summary.workloadKind = template.kind;
    summary.sourceCount = sources.length;
    summary.referenceVersion = catalogEntry.referenceVersion || null;
    return summary;
  }

  function buildFileSequence(files, template) {
    var count = Math.min(Number(template.requestCount || files.length), files.length);
    if (!count) return [];
    var selected = [];
    if (template.accessPattern === 'stack-scroll') {
      var forward = Math.min(Math.ceil(count * 0.65), files.length);
      for (var i = 0; i < forward; i++) selected.push(files[i]);
      var start = Math.max(0, Math.floor(files.length * 0.75));
      for (var j = 0; selected.length < count && j < files.length; j++) {
        selected.push(files[Math.max(0, start - j)]);
      }
    } else {
      var first = Math.min(Math.ceil(count * 0.6), files.length);
      for (var f = 0; f < first; f++) selected.push(files[f]);
      var remaining = count - selected.length;
      for (var r = 0; r < remaining; r++) {
        var idx = Math.min(files.length - 1, Math.floor((r + 1) * (files.length - 1) / Math.max(1, remaining)));
        selected.push(files[idx]);
      }
    }
    return selected.slice(0, count);
  }

  async function runFileSequenceWorkload(template, catalogEntry, imageBaseUrl) {
    var source = catalogEntry.source || {};
    var files = source.files || [];
    if (!files.length) throw new Error('Reference file sequence is missing.');
    var relative = buildFileSequence(files, template);
    var urls = relative.map(function (item) { return joinUrl(imageBaseUrl, item); });
    var started = performance.now();
    var data = await parallelFetch(urls, Number(template.concurrency || 2));
    var summary = summarizeTiles(data);
    summary.bytes = data.results.reduce(function (sum, r) { return sum + r.bytes; }, 0);
    summary.totalMs = performance.now() - started;
    summary.reference = true;
    summary.workloadKind = template.kind;
    summary.sourceCount = 1;
    summary.errors = data.errors;
    return summary;
  }

  async function full(basePath, imageBaseUrl, templateId, referenceCatalog, definitions, viewerElementId) {
    await fetchMeasure(basePath + 'data/1MB.bin');
    var sixteen = await fetchMeasure(basePath + 'data/16MB.bin');
    var sixtyFour = await fetchMeasure(basePath + 'data/64MB.bin');
    var parallel = await parallelFetch([
      basePath + 'data/16MB.bin', basePath + 'data/16MB.bin',
      basePath + 'data/16MB.bin', basePath + 'data/16MB.bin'
    ], 4);

    var template = findTemplate(definitions, templateId);
    if (!template) throw new Error('Selected Full Benchmark workload template was not found: ' + templateId);
    var catalogEntry = referenceCatalog && referenceCatalog.templates ? referenceCatalog.templates[templateId] : null;
    if (!catalogEntry || !catalogEntry.available) throw new Error('Selected reference workload is not installed: ' + templateId);

    var tileResult;
    if (template.kind === 'file-sequence') {
      tileResult = await runFileSequenceWorkload(template, catalogEntry, imageBaseUrl);
    } else {
      tileResult = await runDziWorkload(template, catalogEntry, imageBaseUrl, viewerElementId || 'viewer');
    }

    return {
      mode: 'full',
      serial: [sixteen, sixtyFour],
      parallel: summarizeParallel(parallel),
      tiles: tileResult,
      workload: {
        id: templateId,
        kind: template.kind,
        reference: true,
        profile: referenceCatalog.profile || null,
        referenceVersion: referenceCatalog.referenceVersion || null
      }
    };
  }

  function summarizeParallel(data) {
    if (!data) return null;
    var totalBytes = data.results.reduce(function (sum, r) { return sum + r.bytes; }, 0);
    var seconds = Math.max(data.totalMs / 1000, 0.001);
    return {
      requests: data.results.length,
      failures: data.errors.length,
      totalMs: data.totalMs,
      aggregateMbps: (totalBytes * 8 / 1000000) / seconds,
      errors: data.errors
    };
  }

  function summarizeTiles(data) {
    if (!data) return null;
    var latencies = data.results.map(function (r) { return r.totalMs; });
    return {
      requests: data.results.length,
      failures: data.errors.length,
      p50Ms: percentile(latencies, 50),
      p95Ms: percentile(latencies, 95),
      p99Ms: percentile(latencies, 99),
      totalMs: data.totalMs,
      errors: data.errors
    };
  }

  global.IHBBenchmark = {
    normalizeReferenceCatalog: normalizeReferenceCatalog,
    quick: quick,
    full: full,
    loadWorkloadDefinitions: loadWorkloadDefinitions,
    loadReferenceCatalog: loadReferenceCatalog,
    findTemplate: findTemplate
  };
})(window);
