(function () {
  'use strict';

  var state = {
    server: null,
    client: null,
    scores: { network: null, storage: null, image: null },
    viewer: { status: 'idle', version: null, openMs: null },
    workloads: { definitions: null, catalog: null, selected: null }
  };
  var logEntries = [];
  var basePath = './';
  var $ = function (id) { return document.getElementById(id); };
  var t = function (key, params) { return IHBI18n.t(key, params); };

  function log(key, params) {
    logEntries.push({ time: new Date(), key: key, params: params || {} });
    renderLog();
  }

  function renderLog() {
    var locale = IHBI18n.getLocale ? IHBI18n.getLocale() : 'en-US';
    $('log').textContent = logEntries.map(function (entry) {
      var time;
      try { time = entry.time.toLocaleTimeString(locale); } catch (e) { time = entry.time.toLocaleTimeString(); }
      return '[' + time + '] ' + t(entry.key, entry.params);
    }).join('\n') + (logEntries.length ? '\n' : '');
    $('log').scrollTop = $('log').scrollHeight;
  }

  function fmtBytes(value) {
    if (value == null || !isFinite(Number(value))) return '--';
    var bytes = Number(value);
    if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(2) + ' GiB';
    if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + ' MiB';
    if (bytes >= 1024) return (bytes / 1024).toFixed(1) + ' KiB';
    return Math.round(bytes) + ' B';
  }

  function fmt(value, suffix, digits) {
    if (value == null || !isFinite(value)) return '--';
    return Number(value).toFixed(digits == null ? 1 : digits) + (suffix || '');
  }

  function setText(id, text, cls) {
    var el = $(id);
    if (!el) return;
    el.textContent = text;
    el.classList.remove('value-good', 'value-warn', 'value-bad');
    if (cls) el.classList.add(cls);
  }

  function setTooltip(id, key) {
    var el = $(id);
    if (!el) return;
    el.setAttribute('data-i18n-tooltip', key);
    el.setAttribute('data-tooltip-text', t(key));
  }

  function setSourceStatus(id, ok, error) {
    var el = $(id);
    if (!el) return;
    el.textContent = ok ? t('config.pass') : (error ? t('config.failed') : t('config.unavailable'));
    el.title = error || '';
  }

  function threshold(name, fallback) {
    var value = state.server && state.server.thresholds ? state.server.thresholds[name] : null;
    return value == null ? fallback : Number(value);
  }

  function classifyLower(v, good, warn) {
    if (v == null || !isFinite(v)) return null;
    return v <= good ? 'value-good' : (v <= warn ? 'value-warn' : 'value-bad');
  }

  function classifyHigher(v, good, warn) {
    if (v == null || !isFinite(v)) return null;
    return v >= good ? 'value-good' : (v >= warn ? 'value-warn' : 'value-bad');
  }

  function isLoopbackHost() {
    var host = (location.hostname || '').toLowerCase();
    return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]';
  }

  function localizeIisState(value) {
    if (value === 'Started') return t('value.started');
    if (!value) return t('value.unknown');
    return value;
  }

  function localizeDziFramework(value) {
    if (!value) return t('config.unknownViewer');
    if (value === 'Unknown DZI viewer') return t('config.unknownViewer');
    if (value === 'None') return t('config.directoryMissing');
    return value;
  }

  function workloadStorageKey() { return 'InfrastructureHealth.FullWorkload'; }

  function getStoredWorkload() {
    try { return localStorage.getItem(workloadStorageKey()); } catch (e) { return null; }
  }

  function setStoredWorkload(value) {
    try { localStorage.setItem(workloadStorageKey(), value); } catch (e) { /* optional persistence */ }
  }

  function availableWorkloadIds() {
    var catalog = state.workloads.catalog;
    var definitions = state.workloads.definitions;
    if (!catalog || !definitions || !catalog.templates) return [];
    var enabled = catalog.enabledTemplates || Object.keys(catalog.templates);
    return enabled.filter(function (id) {
      var entry = catalog.templates[id];
      return !!(entry && entry.available && IHBBenchmark.findTemplate(definitions, id));
    });
  }

  function renderWorkloadSelection() {
    var select = $('workloadSelect');
    if (!select) return;
    var ids = availableWorkloadIds();
    select.innerHTML = '';

    if (!ids.length) {
      var missing = document.createElement('option');
      missing.value = '';
      missing.textContent = t('workload.unavailable');
      select.appendChild(missing);
      select.disabled = true;
      $('fullBtn').disabled = true;
      $('workloadDescription').textContent = t('workload.referenceMissing');
      $('workloadMeta').textContent = t('workload.quickStillAvailable');
      return;
    }

    select.disabled = false;
    var desired = state.workloads.selected || getStoredWorkload();
    if (ids.indexOf(desired) < 0) {
      var defaultId = state.workloads.definitions.defaultTemplate;
      desired = ids.indexOf(defaultId) >= 0 ? defaultId : ids[0];
    }
    state.workloads.selected = desired;

    ids.forEach(function (id) {
      var def = IHBBenchmark.findTemplate(state.workloads.definitions, id);
      var option = document.createElement('option');
      option.value = id;
      option.textContent = t(def.labelKey);
      select.appendChild(option);
    });
    select.value = desired;
    $('fullBtn').disabled = false;
    renderSelectedWorkloadDetails();
  }

  function renderSelectedWorkloadDetails() {
    var id = state.workloads.selected;
    var def = IHBBenchmark.findTemplate(state.workloads.definitions, id);
    var catalog = state.workloads.catalog;
    if (!def || !catalog) return;
    $('workloadDescription').textContent = t(def.descriptionKey);
    $('workloadMeta').textContent = t('workload.referenceMeta', {
      version: catalog.referenceVersion || '--',
      profile: catalog.profile || 'Auto',
      files: catalog.payloadFileCount == null ? '--' : catalog.payloadFileCount,
      size: fmtBytes(catalog.payloadBytes)
    });
  }

  async function loadWorkloads() {
    try {
      state.workloads.definitions = await IHBBenchmark.loadWorkloadDefinitions(basePath);
      var imageBase = state.server && state.server.topology && state.server.topology.imageBenchmarkConfigured ? state.server.topology.imageBenchmarkUrl : null;
      state.workloads.catalog = await IHBBenchmark.loadReferenceCatalog(imageBase);
      renderWorkloadSelection();
      if (state.workloads.catalog) {
        log('log.referenceLoaded', { profile: state.workloads.catalog.profile || 'Auto', version: state.workloads.catalog.referenceVersion || '--' });
      } else {
        log('log.referenceUnavailable');
      }
    } catch (e) {
      state.workloads.catalog = null;
      renderWorkloadSelection();
      log('log.referenceError', { error: String(e) });
    }
  }

  async function loadServerHealth() {
    $('runStatus').textContent = t('status.loadingServer');
    try {
      var response = await fetch('api/server-health.json?vlh=' + Date.now(), {
        cache: 'no-store',
        credentials: 'same-origin'
      });
      if (!response.ok) throw new Error('HTTP ' + response.status);
      state.server = await response.json();
      renderServer();
      renderConfiguration();
      await loadWorkloads();
      log('log.serverLoaded', { timestamp: state.server.timestamp });
      $('runStatus').textContent = t('status.ready');
    } catch (e) {
      $('runStatus').textContent = t('status.serverUnavailable');
      log('log.errorServer', { error: String(e) });
    }
  }

  function renderServer() {
    var s = state.server;
    if (!s) return;

    setText('serverName', s.server.hostname || t('topology.serverDefault'));
    setText('serverState', (s.server.iisSite || '') + ' / ' + localizeIisState(s.server.iisState));
    setText('iisState', localizeIisState(s.server.iisState), s.server.iisState === 'Started' ? 'value-good' : 'value-bad');
    setText('cpu', fmt(s.server.cpuPercent, '%', 1));
    setText('memory', fmt(s.server.memoryPercent, '%', 1));
    setText('runAs', s.server.runAs || '--');

    var nicText = '--';
    if (s.server.networkAdapters && s.server.networkAdapters.length) {
      var fastest = s.server.networkAdapters.slice().sort(function (a, b) {
        return (b.speedMbps || 0) - (a.speedMbps || 0);
      })[0];
      nicText = fastest.speedMbps ? fmt(fastest.speedMbps, ' Mbit/s', 0) : fastest.name;
    }
    setText('nic', nicText);

    setText('storagePath', s.storage.path || '--');
    setText('storageAvailability', s.storage.available ? t('value.online') : t('value.offline'), s.storage.available ? 'value-good' : 'value-bad');
    setText('directoryLatency', fmt(s.storage.directoryLatencyMs, ' ms', 1), classifyLower(s.storage.directoryLatencyMs, threshold('StorageDirectoryGoodMs', 10), threshold('StorageDirectoryWarningMs', 30)));
    setText('openLatency', fmt(s.storage.openLatencyMs, ' ms', 1), classifyLower(s.storage.openLatencyMs, threshold('StorageOpenGoodMs', 10), threshold('StorageOpenWarningMs', 30)));

    if (s.storage.mode === 'full') {
      $('storageReadLabel').textContent = t('metrics.fullSampleRead');
      setTooltip('storageReadLabel', 'tooltip.fullSampleRead');
      setText('storageRead', fmt(s.storage.readMBps, ' MB/s', 1), classifyHigher(s.storage.readMBps, threshold('StorageReadGoodMBps', 100), threshold('StorageReadWarningMBps', 50)));
    } else {
      $('storageReadLabel').textContent = t('metrics.quickSampleRead');
      setTooltip('storageReadLabel', 'tooltip.quickSampleRead');
      setText('storageRead', fmt(s.storage.readMBps, ' MB/s', 1));
    }

    setText('smbDialect', s.storage.smbDialect || (s.storage.smbServer ? t('value.notDetected') : t('value.na')));

    var storageMetric = s.storage.available ? fmt(s.storage.openLatencyMs, ' ms', 1) : t('value.storageOffline');
    if (s.storage.available && s.storage.smbDialect) storageMetric += ' / SMB ' + s.storage.smbDialect;
    setText('storageLinkMetric', storageMetric);

    if (s.storage.error) {
      $('storageError').textContent = s.storage.error;
      $('storageError').classList.remove('hidden');
    } else if (s.storage.available && !s.storage.benchmarkAvailable) {
      $('storageError').textContent = t('config.unavailable') + ': ' + s.topology.imageBenchmarkPhysicalPath;
      $('storageError').classList.remove('hidden');
    } else {
      $('storageError').textContent = '';
      $('storageError').classList.add('hidden');
    }

    $('timestamp').textContent = t('status.timestamp', { timestamp: s.timestamp || '--' });

    var directoryScore = IHBScoring.lowerIsBetter(s.storage.directoryLatencyMs, threshold('StorageDirectoryGoodMs', 10), threshold('StorageDirectoryWarningMs', 30));
    var openScore = IHBScoring.lowerIsBetter(s.storage.openLatencyMs, threshold('StorageOpenGoodMs', 10), threshold('StorageOpenWarningMs', 30));
    var storageParts = [directoryScore, openScore];
    if (s.storage.mode === 'full' && s.storage.readScored) {
      storageParts.push(IHBScoring.higherIsBetter(s.storage.readMBps, threshold('StorageReadGoodMBps', 100), threshold('StorageReadWarningMBps', 50)));
    }
    state.scores.storage = s.storage.available ? Math.round(IHBScoring.average(storageParts)) : 0;
    setText('storageScore', state.scores.storage + ' / 100');
    renderOverall();
  }

  function buildDsnDetail(dsn, bitness) {
    dsn = dsn || {};
    var parts = [t('config.detail.dsn', { bitness: bitness, state: dsn.dsnExists ? t('config.present') : t('config.missing') })];
    if (dsn.driver) parts.push(dsn.driver);
    if (dsn.actualServer || dsn.server) parts.push(dsn.actualServer || dsn.server);
    if (dsn.actualDatabase || dsn.database) parts.push(t('config.detail.db', { name: dsn.actualDatabase || dsn.database }));
    if (dsn.dsnLastUser) parts.push(t('config.detail.dsnUser', { user: dsn.dsnLastUser }));
    if (dsn.healthAuthentication) {
      var authText = dsn.healthAuthentication === 'Windows Integrated' ? t('value.windowsIntegrated') : dsn.healthAuthentication;
      parts.push(t('config.detail.healthAuth', { auth: authText }));
    }
    if (dsn.healthRunAs) parts.push(t('config.detail.runAs', { user: dsn.healthRunAs }));
    return parts.join(' / ');
  }

  function renderConfiguration() {
    var s = state.server;
    if (!s || !s.configuration) return;

    var c = s.configuration;
    var registryOk = !!(c.registry && c.registry.available);
    var sql64Ok = !!(c.sql64 && c.sql64.dsnExists && c.sql64.querySucceeded);
    var sql32Ok = !!(c.sql32 && c.sql32.dsnExists && c.sql32.querySucceeded);
    var iisOk = !!(c.iis && c.iis.available);

    setText('registryPath', registryOk ? c.registry.imagePath : '--', registryOk ? 'value-good' : 'value-bad');
    setSourceStatus('registryStatus', registryOk, c.registry && c.registry.error);
    setText('sql64Path', sql64Ok ? c.sql64.imagePath : '--', sql64Ok ? 'value-good' : 'value-bad');
    setSourceStatus('sql64Status', sql64Ok, c.sql64 && c.sql64.error);
    setText('sql32Path', sql32Ok ? c.sql32.imagePath : '--', sql32Ok ? 'value-good' : 'value-bad');
    setSourceStatus('sql32Status', sql32Ok, c.sql32 && c.sql32.error);
    setText('iisImagePath', iisOk ? c.iis.imagePath : '--', iisOk ? 'value-good' : 'value-bad');
    setSourceStatus('iisImageStatus', iisOk, c.iis && c.iis.error);

    var topo = s.topology || {};
    var rawStatus = c.consistency && c.consistency.status ? c.consistency.status : 'WARNING';
    var dziFrameworkOk = !!(topo.dziAvailable && topo.dziFramework && topo.dziFramework !== 'None' && topo.dziFramework !== 'Unknown DZI viewer');
    var status = rawStatus;
    var messageKey;
    if (c.consistency && c.consistency.allMatch === true) messageKey = 'config.message.match';
    else if (c.consistency && c.consistency.allMatch === false) messageKey = 'config.message.mismatch';
    else messageKey = 'config.message.unknown';
    if (status === 'PASS' && !dziFrameworkOk) status = 'WARNING';

    var label = $('configurationLabel');
    label.textContent = status === 'PASS' ? t('config.pass') : t('config.warning');
    label.className = 'pill ' + (status === 'PASS' ? 'good' : 'warn');
    $('configurationMessage').textContent = t(messageKey) + (!dziFrameworkOk ? ' ' + t('config.message.dziIncomplete') : '');

    $('dsn64Detail').textContent = buildDsnDetail(c.sql64, '64-bit');
    $('dsn32Detail').textContent = buildDsnDetail(c.sql32, '32-bit');

    var dziText = topo.dziAvailable ? localizeDziFramework(topo.dziFramework) : t('config.directoryMissing');
    if (topo.dziFrameworkPath) dziText += ' / ' + topo.dziFrameworkPath;
    $('dziDetail').textContent = t('config.detail.dziFramework', { value: dziText });

    var components = topo.legacySeadragonComponents || null;
    if (components && topo.legacySeadragonDetected) {
      var componentNames = [
        ['Core', components.core], ['Config', components.config], ['DeepZoom', components.deepZoom], ['TileSource', components.tileSource], ['Viewer', components.viewer]
      ];
      var compText = componentNames.map(function (item) { return item[0] + '=' + (item[1] ? t('config.component.ok') : t('config.component.missing')); }).join(' / ');
      $('dziComponentsDetail').textContent = t('config.detail.legacyComponents', { value: compText });
    } else {
      $('dziComponentsDetail').textContent = t('config.detail.dziComponents', { value: topo.dziAvailable ? t('config.notApplicable') : t('config.directoryMissing') });
    }

    var previewText = (topo.healthPreviewEngine || 'OpenSeadragon') + ' ' + (topo.healthPreviewVersion || '--') + ' / ' + (topo.healthPreviewAvailable ? t('config.ready') : t('config.unavailable'));
    $('previewDetail').textContent = t('config.detail.previewEngine', { value: previewText });

    if (c.consistency && c.consistency.allMatch === false && !logEntries.some(function (x) { return x.key === 'log.warningMismatch'; })) log('log.warningMismatch');
    if (!sql64Ok && !logEntries.some(function (x) { return x.key === 'log.warningSql64'; })) log('log.warningSql64');
    if (!sql32Ok && !logEntries.some(function (x) { return x.key === 'log.warningSql32'; })) log('log.warningSql32');
  }

  function renderBenchmark(result) {
    state.client = result;
    var serial = result.serial || [];
    var representative = serial[serial.length - 1] || null;
    var loopback = isLoopbackHost();

    $('loopbackNotice').classList.toggle('hidden', !loopback);

    if (representative) {
      setText('ttfb', fmt(representative.ttfbMs, ' ms', 1), classifyLower(representative.ttfbMs, threshold('ClientTtfbGoodMs', 15), threshold('ClientTtfbWarningMs', 50)));
      setText('throughput', fmt(representative.mbps, ' Mbit/s', 1), classifyHigher(representative.mbps, threshold('ClientThroughputGoodMbps', 100), threshold('ClientThroughputWarningMbps', 50)));

      if (loopback) {
        state.scores.network = null;
        setText('networkScore', t('value.loopback'), 'value-warn');
        setText('clientLinkMetric', t('value.localLoopback'));
      } else {
        setText('clientLinkMetric', fmt(representative.mbps, ' Mbit/s', 0) + ' / ' + fmt(representative.ttfbMs, ' ms TTFB', 1));
        var ttfbScore = IHBScoring.lowerIsBetter(representative.ttfbMs, threshold('ClientTtfbGoodMs', 15), threshold('ClientTtfbWarningMs', 50));
        var throughputScore = IHBScoring.higherIsBetter(representative.mbps, threshold('ClientThroughputGoodMbps', 100), threshold('ClientThroughputWarningMbps', 50));
        state.scores.network = Math.round(IHBScoring.average([ttfbScore, throughputScore]));
        setText('networkScore', state.scores.network + ' / 100');
      }
    }

    if (result.parallel) setText('parallelThroughput', fmt(result.parallel.aggregateMbps, ' Mbit/s', 1));

    if (result.tiles) {
      var fileSequence = !!(result.workload && result.workload.kind === 'file-sequence');
      var realFull = result.mode === 'full' && result.workload && result.workload.reference;
      $('latencyP50Label').textContent = t(fileSequence ? 'metrics.requestP50' : 'metrics.tileP50');
      $('latencyP95Label').textContent = t(fileSequence ? 'metrics.requestP95' : 'metrics.tileP95');
      $('failuresLabel').textContent = t(fileSequence ? 'metrics.requestFailures' : 'metrics.tileFailures');
      $('loadLabel').textContent = t(realFull ? 'metrics.workloadDuration' : 'metrics.viewportLoad');
      setTooltip('latencyP50Label', fileSequence ? 'tooltip.requestP50' : 'tooltip.tileP50');
      setTooltip('latencyP95Label', fileSequence ? 'tooltip.requestP95' : 'tooltip.tileP95');
      setTooltip('failuresLabel', fileSequence ? 'tooltip.requestFailures' : 'tooltip.tileFailures');
      setTooltip('loadLabel', realFull ? 'tooltip.workloadDuration' : 'tooltip.viewportLoad');
      setText('tileP50', fmt(result.tiles.p50Ms, ' ms', 1));
      setText('tileP95', fmt(result.tiles.p95Ms, ' ms', 1), classifyLower(result.tiles.p95Ms, threshold('TileP95GoodMs', 100), threshold('TileP95WarningMs', 250)));
      setText('tileFailures', String(result.tiles.failures), result.tiles.failures === 0 ? 'value-good' : 'value-bad');
      setText('viewerLoad', fmt(result.tiles.totalMs, ' ms', 0));
      var p95Score = IHBScoring.lowerIsBetter(result.tiles.p95Ms, threshold('TileP95GoodMs', 100), threshold('TileP95WarningMs', 250));
      var failureScore = result.tiles.failures === 0 ? 100 : Math.max(0, 100 - result.tiles.failures * 25);
      state.scores.image = Math.round(IHBScoring.average([p95Score, failureScore]));
      setText('imageScore', state.scores.image + ' / 100');
    }
    renderOverall();
  }

  function scoreLabelKey(score) {
    if (score == null) return 'overall.waiting';
    if (score >= 85) return 'overall.excellent';
    if (score >= 70) return 'overall.good';
    if (score >= 50) return 'overall.degraded';
    return 'overall.poor';
  }

  function renderOverall() {
    var scores = state.scores;
    var overall = IHBScoring.overall([scores.network, scores.storage, scores.image]);
    $('overallScore').textContent = overall == null ? '--' : overall;
    var meta = IHBScoring.label(overall);
    $('overallLabel').textContent = t(scoreLabelKey(overall));
    $('overallLabel').className = 'pill ' + meta.cls;

    var available = [
      { key: 'segment.network', score: scores.network },
      { key: 'segment.storage', score: scores.storage },
      { key: 'segment.image', score: scores.image }
    ].filter(function (x) { return x.score != null; });

    if (!available.length) {
      $('bottleneck').textContent = t('overall.runToIdentify');
      return;
    }
    available.sort(function (a, b) { return a.score - b.score; });
    var worst = available[0];
    $('bottleneck').textContent = worst.score >= 85
      ? t('overall.noBottleneck')
      : t('overall.likelyBottleneck', { segment: t(worst.key), score: worst.score });
  }

  async function run(mode) {
    var quickBtn = $('quickBtn');
    var fullBtn = $('fullBtn');
    if (mode === 'full' && availableWorkloadIds().length === 0) {
      $('runStatus').textContent = t('workload.referenceMissing');
      log('log.referenceUnavailable');
      return;
    }
    quickBtn.disabled = true;
    fullBtn.disabled = true;
    $('runStatus').textContent = mode === 'full' ? t('status.runningFull') : t('status.runningQuick');
    log(mode === 'full' ? 'log.startingFull' : 'log.startingQuick');

    try {
      var imageBase = state.server && state.server.topology && state.server.topology.imageBenchmarkConfigured ? state.server.topology.imageBenchmarkUrl : null;
      var result = mode === 'full'
        ? await IHBBenchmark.full(basePath, imageBase, state.workloads.selected, state.workloads.catalog, state.workloads.definitions, 'viewer')
        : await IHBBenchmark.quick(basePath, imageBase);
      renderBenchmark(result);
      log('log.clientCompleted');
      if (result.tiles) log('log.tileBenchmark', { p95: fmt(result.tiles.p95Ms, ' ms', 1), failures: result.tiles.failures });
      $('runStatus').textContent = t('status.completed');
      if (mode === 'full' && result.workload) {
        if (result.workload.kind === 'dzi-navigation' || result.workload.kind === 'dzi-series') {
          state.viewer.status = 'reference';
          state.viewer.version = (window.OpenSeadragon && OpenSeadragon.version && OpenSeadragon.version.versionStr) || '';
        } else {
          state.viewer.status = 'sequence';
          $('viewer').innerHTML = '<div class="viewer-placeholder">' + t('preview.sequencePlaceholder') + '</div>';
        }
        renderViewerNote();
      } else if (mode === 'quick') {
        startViewer();
      }
    } catch (e) {
      $('runStatus').textContent = t('status.failed');
      log('log.benchmarkError', { error: String(e) });
    } finally {
      quickBtn.disabled = false;
      fullBtn.disabled = availableWorkloadIds().length === 0;
    }
  }

  function renderViewerNote() {
    if (state.viewer.status === 'unavailable') {
      $('viewerNote').textContent = t('preview.note.unavailable');
    } else if (state.viewer.status === 'reference') {
      $('viewerNote').textContent = t('preview.note.referenceLoaded', { version: state.viewer.version || '' });
    } else if (state.viewer.status === 'synthetic') {
      $('viewerNote').textContent = t('preview.note.loaded', { version: state.viewer.version || '' });
    } else if (state.viewer.status === 'sequence') {
      $('viewerNote').textContent = t('preview.note.sequence');
    } else {
      $('viewerNote').textContent = t('preview.note.rawIndependent');
    }
  }

  function startViewer() {
    if (!(state.server && state.server.topology && state.server.topology.imageBenchmarkConfigured)) return;
    if (!window.OpenSeadragon) {
      state.viewer.status = 'unavailable';
      renderViewerNote();
      return;
    }

    try {
      $('viewer').innerHTML = '';
      var started = performance.now();
      var imageBase = state.server.topology.imageBenchmarkUrl.replace(/\/$/, '');
      var cacheToken = Date.now();
      var tileSource = {
        width: 1024, height: 1024, tileSize: 256, tileOverlap: 0, minLevel: 0, maxLevel: 10,
        getTileUrl: function (level, x, y) { return imageBase + '/benchmark_files/' + level + '/' + x + '_' + y + '.png?vlh=' + cacheToken; }
      };
      var viewer = OpenSeadragon({ id: 'viewer', tileSources: tileSource, showNavigationControl: false, showNavigator: false, animationTime: 0.2, blendTime: 0 });
      viewer.addOnceHandler('open', function () {
        state.viewer.status = 'synthetic';
        state.viewer.version = (OpenSeadragon.version && OpenSeadragon.version.versionStr) || '';
        state.viewer.openMs = performance.now() - started;
        renderViewerNote();
        log('log.viewerOpened', { time: fmt(state.viewer.openMs, ' ms', 0) });
      });
      viewer.addHandler('open-failed', function (ev) { log('log.viewerOpenFailed', { error: ev.message || t('log.unknownError') }); });
    } catch (e) {
      log('log.viewerInitFailed', { error: String(e) });
    }
  }

  function exportJson() {
    var payload = {
      exportedAt: new Date().toISOString(),
      page: location.href,
      uiLocale: IHBI18n.getLocale(),
      loopbackClientTest: isLoopbackHost(),
      userAgent: navigator.userAgent,
      referenceBenchmark: {
        selectedTemplate: state.workloads.selected,
        profile: state.workloads.catalog ? state.workloads.catalog.profile : null,
        referenceVersion: state.workloads.catalog ? state.workloads.catalog.referenceVersion : null,
        datasetSha256: state.workloads.catalog ? state.workloads.catalog.datasetSha256 : null
      },
      serverHealth: state.server,
      clientBenchmark: state.client,
      scores: state.scores,
      overallScore: IHBScoring.overall([state.scores.network, state.scores.storage, state.scores.image])
    };
    var blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = 'Infrastructure-Health-Benchmark-' + new Date().toISOString().replace(/[:.]/g, '-') + '.json';
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  }

  function renderLanguageDependentState() {
    $('clientName').textContent = navigator.userAgent.indexOf('Windows') >= 0 ? t('client.windowsChromium') : navigator.userAgent;
    if (state.server) {
      renderServer();
      renderConfiguration();
    }
    if (state.client) renderBenchmark(state.client);
    renderWorkloadSelection();
    renderViewerNote();
    renderLog();
  }

  function bindEvents() {
    $('quickBtn').addEventListener('click', function () { run('quick'); });
    $('fullBtn').addEventListener('click', function () { run('full'); });
    $('refreshBtn').addEventListener('click', loadServerHealth);
    $('exportBtn').addEventListener('click', exportJson);
    $('workloadSelect').addEventListener('change', function () {
      state.workloads.selected = this.value;
      setStoredWorkload(this.value);
      renderSelectedWorkloadDetails();
      log('log.workloadSelected', { workload: this.options[this.selectedIndex] ? this.options[this.selectedIndex].text : this.value });
    });
    window.addEventListener('infrastructure-language-changed', function () { renderLanguageDependentState(); });
  }

  IHBI18n.init().then(function () {
    bindEvents();
    renderLanguageDependentState();
    loadServerHealth().then(function () { setTimeout(function () { run('quick'); }, 300); });
  }).catch(function () {
    bindEvents();
    loadServerHealth().then(function () { setTimeout(function () { run('quick'); }, 300); });
  });
})();
