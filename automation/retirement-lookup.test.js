'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const handler = require('./retirement-lookup.js');
const p = handler.internals;
const SUB = '11111111-2222-3333-4444-555555555555';
const INPUT = { subscriptionIds: [SUB], retirementHorizonMonths: 6 };
const NOW = new Date('2026-11-16T12:00:00Z');

function catalog(rows) {
    return `# Synthetic retirement catalog\n### General purpose retired sizes\n\n| Series name | Retirement Status | Retirement Announcement | Planned Retirement Date | Modernization guide |\n| --- | --- | --- | --- | --- |\n${rows.map(([series, date, guide = 'guide']) => `| ${series} | Announced | - | ${date} | [Guide](${guide}) |`).join('\n')}`;
}

function response(body, status = 200, markdown = false) {
    return new Response(markdown ? body : JSON.stringify(body), {
        status, headers: { 'Content-Type': markdown ? 'text/markdown' : 'application/json' }
    });
}

function resource(name = 'Standard_Z4s_v8', region = 'eastus') {
    return {
        id: `/subscriptions/${SUB}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-${name}`,
        SubscriptionId: SUB, SubscriptionName: 'Synthetic subscription', ResourceGroup: 'rg',
        ResourceName: `vm-${name}`, Type: 'VM', Sku: name, Region: region
    };
}

function mockSources(options = {}) {
    const calls = [];
    const fetcher = async (value, init = {}) => {
        const url = new URL(value);
        calls.push({ url, init });
        if (url.hostname === 'learn.microsoft.com') {
            if (url.pathname.endsWith('retirements-and-capacity-restrictions')) {
                return response(options.catalog || catalog([['Zsv8-series', '03/31/27']]), 200, true);
            }
            return response(options.detail || '# Synthetic migration guidance\nSelect a suitable size.', 200, true);
        }
        assert.equal(url.origin, 'https://management.azure.com');
        assert.equal(init.headers.Authorization, 'Bearer synthetic-token');
        if (url.pathname.endsWith('/resources')) {
            const body = JSON.parse(init.body);
            assert.match(body.query, /\bproject id,/);
            if (options.argPages) {
                const index = body.options.$skipToken ? 1 : 0;
                return response(options.argPages[index]);
            }
            return response({ data: options.resources || [resource()], resultTruncated: 'false' });
        }
        if (url.pathname.endsWith('/locations')) {
            return response({ value: [
                { name: 'eastus', displayName: 'East US' },
                { name: 'eastus2', displayName: 'East US 2' },
                { name: 'uaenorth', displayName: 'UAE North' }
            ] });
        }
        if (url.pathname.endsWith('/skus')) {
            assert.equal(url.searchParams.get('$filter'), "location eq 'eastus'");
            return response({ value: options.skus || [{
                resourceType: 'virtualMachines', name: 'Standard_Z4s_v8',
                capabilities: [{ name: 'vCPUs', value: '4' }, { name: 'MemoryGB', value: '16' }]
            }] });
        }
        if (url.pathname === `/subscriptions/${SUB}`) {
            return response({ subscriptionId: SUB }, options.accessStatus || 200);
        }
        throw new Error(`Unexpected mock request: ${value}`);
    };
    return { calls, request: p.createClient(fetcher), fetcher };
}

test('series matching derives unseen families, generations, features and qualifiers', () => {
    const cases = [
        ['Zsv8-series', 'Standard_Z4s_v8', true],
        ['Zsv8-series', 'Standard_Z4s_v9', false],
        ['Zsv8-series', 'Standard_Z4_v8', false],
        ['DCas_cc_v5/DCads_cc_v5-series', 'Standard_DC4ads_cc_v5', true],
        ['DCas_cc_v5/DCads_cc_v5-series', 'Standard_DC4ads_v5', false],
        ['NCasT4_v3-series', 'Standard_NC4as_T4_v3', true],
        ['NCv3-series', 'Standard_NC4as_T4_v3', false],
        ['NCv3-NC24rs Series', 'Standard_NC24rs_v3', true],
        ['NCv3-NC24rs Series', 'Standard_NC6s_v3', false],
        ['Dsv2-series', 'Standard_DS2_v2_Promo', true],
        ['B-series (V1)', 'Standard_B1ls2', true],
        ['B-series (V1)', 'Standard_B2s_v2', false],
        ['HBv2-series', 'Standard_HB120-16rs_v2', true],
        ['NVv3-series', 'Standard_NV12hs_v3', true],
        ['Standard_M192is_v2', 'Standard_M192ids_v2', false]
    ];
    for (const [label, sku, expected] of cases) {
        assert.equal(p.seriesRules(label).some(rule => p.matchesSku(rule, sku)), expected, `${label} / ${sku}`);
    }
});

test('parses published dates, slash labels and exact sizes, excluding dedicated hosts', () => {
    const text = catalog([['Zsv8/Zdsv8-series', '03/31/2027'], ['Standard\\_Z192is\\_v8', '04/01/27']])
        + '\n### ADH retired sizes\n' + catalog([['Zsv8-Type1', '03/31/27']]).split('### General purpose retired sizes')[1];
    const entries = p.parseCatalog(text);
    assert.equal(entries.length, 2);
    assert.equal(entries[0].retirementDate, '2027-03-31');
    assert.equal(entries[1].rules[0].exact, 'standard_z192is_v8');
    assert.ok(entries[0].guideUrl.startsWith('https://learn.microsoft.com/'));
});

test('format changes, invalid dates and foreign guide links fail explicitly', () => {
    for (const text of [
        '# No table', catalog([['Unfamiliar ! label', '03/31/27']]),
        catalog([['Zsv8-series', '02/30/27']]),
        catalog([['Zsv8-series', '03/31/27', 'https://example.org/guide']]),
        catalog([['Zsv8-series', '03/31/27']]).replace('Planned Retirement Date', 'Different field'),
        catalog([['Zsv8-series', '03/31/27']]) + '\n### New category retired sizes\nNo table here',
        catalog([['Zsv8-series', '03/31/27']]).replace('Announced', 'Cancelled')
    ]) assert.throws(() => p.parseCatalog(text));
});

test('uses calendar-month horizon with month-end clamping', () => {
    assert.equal(p.cutoffDate(new Date('2027-08-31T00:00:00Z'), 6), '2028-02-29');
    assert.equal(p.cutoffDate(NOW, 6), '2027-05-16');
});

test('resolves regional extensions from live location names, without region/date maps', () => {
    const entry = p.parseCatalog(catalog([['Zsv8-series', '09/30/26']]))[0];
    const locations = [
        { name: 'eastus', displayName: 'East US' }, { name: 'eastus2', displayName: 'East US 2' },
        { name: 'uaenorth', displayName: 'UAE North' }
    ];
    const detail = 'If using this series in East US 2, the extension date is January 31, 2027.';
    assert.equal(p.resolveDeadline(entry, detail, 'eastus2', locations).date, '2027-01-31');
    assert.equal(p.resolveDeadline(entry, detail, 'eastus', locations).date, '2026-09-30');
    assert.match(p.resolveDeadline(entry, 'A regional extension is available on request.', 'eastus', locations).review, /could not be resolved/);
    assert.equal(p.resolveDeadline(entry, "This retirement doesn't apply to East US 2.", 'eastus2', locations).excluded, true);
    assert.match(p.resolveDeadline(entry,
        'The extension dates in East US and East US 2 are January 31, 2027 and June 30, 2027, respectively.',
        'eastus', locations).review, /could not be resolved/);
});

test('prefers explicitly named feature series over broader family matches', () => {
    const entries = p.parseCatalog(catalog([['Zv8-series', '03/31/27'], ['Zsv8-series', '04/30/27']]));
    assert.deepEqual(p.selectEntries(entries, 'Standard_Z4s_v8').map(e => e.retirementDate), ['2027-04-30']);
});

test('full scan uses live metadata and official guidance, including retirement day', async () => {
    const sources = mockSources({ catalog: catalog([['Zsv8-series', '11/16/26']]) });
    const result = await p.scan(INPUT, 'synthetic-token', sources.request, NOW);
    assert.equal(result.scannedSubscriptions, 1);
    assert.equal(result.scannedResources, 1);
    assert.equal(result.resources[0].Status, 'Retired');
    assert.equal(result.resources[0].vCPUs, '4');
    assert.equal(result.resources[0].MemoryGB, '16');
    assert.match(result.resources[0].MigrationGuidance, /learn\.microsoft\.com/);
    assert.equal(result.resources[0].RecommendedSku, undefined);
    assert.deepEqual(result.warnings, []);
});

test('does not classify a different generation as retiring or fetch unnecessary SKU data', async () => {
    const sources = mockSources({ resources: [resource('Standard_Z4s_v9')] });
    const result = await p.scan(INPUT, 'synthetic-token', sources.request, NOW);
    assert.equal(result.totalFindings, 0);
    assert.ok(!sources.calls.some(call => call.url.pathname.endsWith('/skus')));
});

test('missing retired SKU metadata stays visible and produces a warning', async () => {
    const sources = mockSources({ skus: [] });
    const result = await p.scan(INPUT, 'synthetic-token', sources.request, NOW);
    assert.equal(result.totalFindings, 1);
    assert.equal(result.resources[0].vCPUs, 'Unavailable');
    assert.equal(result.warnings.length, 1);
});

test('a resource with no scalar SKU produces an explicit warning, not a clean report', async () => {
    const item = { ...resource(), Type: 'VMSS (0)', Sku: '' };
    const sources = mockSources({ resources: [item] });
    const result = await p.scan(INPUT, 'synthetic-token', sources.request, NOW);
    assert.equal(result.totalFindings, 0);
    assert.equal(result.scannedResources, 1);
    assert.match(result.warnings[0], /No scalar SKU/);
    assert.ok(result.warnings[0].includes(item.id));
});

test('Resource Graph inventory is paginated before the 1000-row email cap', async () => {
    const first = Array.from({ length: 1000 }, (_, i) => ({ ...resource(), id: `/synthetic/${i}` }));
    const sources = mockSources({ argPages: [
        { data: first, $skipToken: 'next', resultTruncated: 'true' },
        { data: [{ ...resource(), id: '/synthetic/last' }], resultTruncated: 'false' }
    ] });
    const result = await p.scan(INPUT, 'synthetic-token', sources.request, NOW);
    assert.equal(result.scannedResources, 1001);
    assert.equal(result.totalFindings, 1001);
    assert.equal(result.resources.length, 1000);
    assert.equal(sources.calls.filter(call => call.url.pathname.endsWith('/resources')).length, 2);
});

test('missing subscription access fails rather than reporting partial coverage', async () => {
    const sources = mockSources({ accessStatus: 403 });
    await assert.rejects(p.scan(INPUT, 'synthetic-token', sources.request, NOW), /403/);
    assert.ok(!sources.calls.some(call => call.url.pathname.endsWith('/resources')));
});

test('pagination rejects foreign hosts, repeated tokens and missing data', async () => {
    const foreign = async () => response({ value: [], nextLink: 'https://example.org/steal-token' });
    await assert.rejects(p.collection('https://management.azure.com/list', 'secret', p.createClient(foreign)), /continuation URL/);
    const repeated = mockSources({ argPages: [
        { data: [], $skipToken: 'same' }, { data: [], $skipToken: 'same' }
    ] });
    await assert.rejects(p.inventory([SUB], 'synthetic-token', repeated.request), /repeated continuation token/);
    const missing = mockSources({ argPages: [{ resultTruncated: 'false' }] });
    await assert.rejects(p.inventory([SUB], 'synthetic-token', missing.request), /missing data/);
    const truncated = mockSources({ argPages: [{ data: [], resultTruncated: 'true' }] });
    await assert.rejects(p.inventory([SUB], 'synthetic-token', truncated.request), /truncated inventory/);
    const omitted = mockSources({ argPages: [{ data: [], totalRecords: 1 }] });
    await assert.rejects(p.inventory([SUB], 'synthetic-token', omitted.request), /omitted inventory/);
});

test('Compute SKU API follows pagination', async () => {
    let count = 0;
    const result = await p.collection('https://management.azure.com/list', 'token', p.createClient(async () => {
        count++;
        return response({ value: [{ name: `sku-${count}` }], ...(count === 1 ? { nextLink: 'https://management.azure.com/list?page=2' } : {}) });
    }));
    assert.equal(count, 2);
    assert.equal(result.length, 2);
});

test('lookup failures return non-success responses to the Logic App', async () => {
    const env = { endpoint: process.env.IDENTITY_ENDPOINT, header: process.env.IDENTITY_HEADER };
    delete process.env.IDENTITY_ENDPOINT;
    delete process.env.IDENTITY_HEADER;
    try {
        const context = { log: { error() {} } };
        await handler(context, { body: INPUT });
        assert.equal(context.res.status, 502);
        assert.equal(context.res.body.error, 'RetirementLookupFailed');
    } finally {
        if (env.endpoint !== undefined) process.env.IDENTITY_ENDPOINT = env.endpoint;
        if (env.header !== undefined) process.env.IDENTITY_HEADER = env.header;
    }
});

test('HTTP handler obtains managed identity credentials and returns the complete lookup contract', async () => {
    const previous = { fetch: global.fetch, endpoint: process.env.IDENTITY_ENDPOINT, header: process.env.IDENTITY_HEADER };
    const sources = mockSources();
    process.env.IDENTITY_ENDPOINT = 'http://identity.local/token';
    process.env.IDENTITY_HEADER = 'synthetic-identity-header';
    global.fetch = async (value, init) => {
        const url = new URL(value);
        if (url.hostname === 'identity.local') {
            assert.equal(init.headers['X-IDENTITY-HEADER'], 'synthetic-identity-header');
            assert.equal(url.searchParams.get('resource'), 'https://management.azure.com/');
            return response({ access_token: 'synthetic-token' });
        }
        return sources.fetcher(value, init);
    };
    try {
        const context = { log: { error(message) { assert.fail(message); } } };
        await handler(context, { body: { ...INPUT, retirementHorizonMonths: 60 } });
        assert.equal(context.res.status, 200);
        assert.equal(context.res.body.totalFindings, 1);
        assert.equal(context.res.body.resources[0].Sku, 'Standard_Z4s_v8');
        assert.ok(Array.isArray(context.res.body.warnings));
    } finally {
        global.fetch = previous.fetch;
        if (previous.endpoint === undefined) delete process.env.IDENTITY_ENDPOINT;
        else process.env.IDENTITY_ENDPOINT = previous.endpoint;
        if (previous.header === undefined) delete process.env.IDENTITY_HEADER;
        else process.env.IDENTITY_HEADER = previous.header;
    }
});

test('deployment embeds exact source, secures lookup keys, and grants the parser Reader', () => {
    const template = JSON.parse(fs.readFileSync(path.join(__dirname, 'deploy-vm-retirement-notifier.json'), 'utf8'));
    const find = type => template.resources.find(resource => resource.type === type);
    const func = find('Microsoft.Web/sites/functions');
    assert.equal(func.properties.files['index.js'], fs.readFileSync(path.join(__dirname, 'retirement-lookup.js'), 'utf8').replace(/\r\n/g, '\n'));
    assert.equal(func.properties.config.bindings[0].authLevel, 'function');
    const workflow = find('Microsoft.Logic/workflows').properties;
    assert.equal(workflow.state, "[parameters('workflowState')]");
    assert.deepEqual(workflow.definition.actions.Lookup_retirements.runtimeConfiguration.secureData.properties, ['inputs', 'outputs']);
    assert.match(find('Microsoft.Resources/deployments').properties.parameters.principalId.value, /Microsoft.Web\/sites/);
    assert.ok(!JSON.stringify(template).includes('microsoft.advisor'));
    const schedule = workflow.definition.triggers.Every_other_Monday_0900.recurrence;
    assert.equal(schedule.interval, 2);
    assert.equal(schedule.timeZone, 'Turkey Standard Time');
});

test('live Microsoft Learn catalog, linked guides and regional deadlines', { skip: !process.env.LIVE_LEARN }, async () => {
    const request = p.createClient();
    const page = await p.learnPage(p.CATALOG_URL, request);
    const entries = p.parseCatalog(page.text);
    for (const url of new Set(entries.map(entry => entry.guideUrl))) {
        const guide = await p.learnPage(url, request);
        assert.ok(guide.text.length > 100);
    }
    const locations = [
        { name: 'uaenorth', displayName: 'UAE North' },
        { name: 'jioindiawest', displayName: 'Jio India West' },
        { name: 'usgovvirginia', displayName: 'US Gov Virginia' },
        { name: 'usgovarizona', displayName: 'US Gov Arizona' },
        { name: 'chinanorth3', displayName: 'China North 3' }
    ];
    for (const [sku, location, expected] of [
        ['Standard_NV12hs_v3', 'uaenorth', '2027-01-31'],
        ['Standard_NC6s_v3', 'jioindiawest', '2027-06-30'],
        ['Standard_NC6s_v3', 'usgovvirginia', '2026-12-31']
    ]) {
        const entry = p.selectEntries(entries, sku)[0];
        assert.ok(entry, `Live catalog must include ${sku}`);
        const guide = await p.learnPage(entry.guideUrl, request);
        const deadline = p.resolveDeadline(entry, guide.text, location, locations);
        assert.equal(deadline.review, '');
        assert.equal(deadline.date, expected);
    }
});
