'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const context = { window: {} };
vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(root, 'Web/js/benchmark.js'), 'utf8'), context);
const api = context.window.IHBBenchmark;
const old = {
    profile: 'VS3000', enabledTemplates: ['vivablock', 'vivastack', 'vivacube'],
    templates: {
        vivablock: { available: true, sources: [{tileBaseUrl: 'reference/vivablock/block1/tiles'}] },
        vivastack: { available: true }, vivacube: { available: true }
    }
};
const updated = api.normalizeReferenceCatalog(old);
assert.equal(updated.profile, 'SingleField');
assert.equal(updated.enabledTemplates.join(','), 'xy-mosaic,z-stack,volume');
assert.equal(updated.templates['xy-mosaic'].sources[0].tileBaseUrl, 'reference/vivablock/block1/tiles');
assert.equal(updated.templates.vivablock, undefined);
assert.equal(api.normalizeReferenceCatalog(null), null);
assert.throws(() => api.normalizeReferenceCatalog({templates: {vivablock: {}, 'xy-mosaic': {}}}), /Ambiguous/);
const generic = {templates: {'xy-mosaic': {available: true}}, enabledTemplates: ['xy-mosaic']};
assert.equal(api.normalizeReferenceCatalog(generic), generic);
const definitions = JSON.parse(fs.readFileSync(path.join(root, 'Web/workloads/templates.json')));
assert.equal(definitions.templates.map(t => t.id).sort().join(','), 'single-images,volume,xy-mosaic,z-stack');
for (const locale of fs.readdirSync(path.join(root, 'Web/i18n')).filter(n=> n !== 'manifest.json' && n.endsWith('.json'))) {
    const strings = JSON.parse(fs.readFileSync(path.join(root, 'Web/i18n', locale)));
    assert.equal(strings['app.title'], 'Infrastructure Health & Benchmark');
    for (const t of definitions.templates) {
        assert.ok(strings[t.labelKey], `${locale}: ${t.labelKey}`);
        assert.ok(strings[t.descriptionKey], `${locale}: ${t.descriptionKey}`);
    }
}
console.log('Workload IDs, legacy compatibility, payload paths and locale keys passed.');
