'use strict';

const LEARN_ROOT = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/';
const CATALOG_URL = `${LEARN_ROOT}retirements-and-capacity-restrictions`;
const ARM_ROOT = 'https://management.azure.com';
const DAY = 86400000;
const INVENTORY_QUERY = `resources
| where type =~ 'microsoft.compute/virtualmachines' or type =~ 'microsoft.compute/virtualmachinescalesets'
| extend Sku = iff(type =~ 'microsoft.compute/virtualmachines', tostring(properties.hardwareProfile.vmSize), tostring(sku.name))
| join kind=leftouter (resourcecontainers | where type =~ 'microsoft.resources/subscriptions' | project subscriptionId, SubscriptionName = name) on subscriptionId
| project id, SubscriptionId = subscriptionId, SubscriptionName, ResourceGroup = resourceGroup, ResourceName = name, Type = iff(type =~ 'microsoft.compute/virtualmachines', 'VM', strcat('VMSS (', tostring(sku.capacity), ')')), Sku, Region = location`;

function plain(value) {
    return value.replace(/\\_/g, '_').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
        .replace(/<[^>]+>/g, ' ').replace(/[*`]/g, '').trim();
}

function dateOnly(value) {
    const m = plain(value).match(/^(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})$/);
    if (!m) throw new Error(`Unrecognized retirement date: ${value}`);
    const year = m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3]);
    const iso = `${year}-${m[1].padStart(2, '0')}-${m[2].padStart(2, '0')}`;
    if (!Number.isFinite(Date.parse(iso)) || new Date(iso).toISOString().slice(0, 10) !== iso) {
        throw new Error(`Invalid retirement date: ${value}`);
    }
    return iso;
}

function seriesRules(label) {
    const name = plain(label);
    if (/^(Standard|Basic)_/i.test(name)) {
        return [{ exact: name.toLowerCase(), specificity: 100 }];
    }
    const cleaned = name.replace(/\s*\(V1\)/gi, '').replace(/-?series\b/gi, '').trim();
    const qualified = cleaned.match(/v(\d+)-([A-Z]+\d+[a-z]+)$/);
    if (qualified) {
        return [{ exact: `standard_${qualified[2]}_v${qualified[1]}`.toLowerCase(), specificity: 100 }];
    }
    return cleaned.split(/[\/,]/).map(part => {
        const version = part.trim().match(/_?v(\d+)$/);
        const stem = version ? part.trim().slice(0, version.index) : part.trim();
        const m = stem.match(/^([A-Z]+)([a-z][A-Za-z0-9_]*|_[A-Za-z0-9_]+)?$/);
        if (!m) throw new Error(`Unsupported published series label: ${label}`);
        const features = (m[2] || '').replace(/_/g, '').toLowerCase();
        return {
            family: m[1].toLowerCase(), features, version: Number(version?.[1] || 1),
            specificity: 1 + features.length
        };
    });
}

function matchesSku(rule, sku) {
    if (rule.exact) return rule.exact === sku.toLowerCase();
    const name = sku.replace(/_Promo$/i, '');
    const version = name.match(/_v(\d+)$/i);
    const stem = version ? name.slice(0, version.index) : name;
    const m = stem.match(/^(?:Standard|Basic)_([A-Za-z]+)\d+(?:-\d+)?([A-Za-z][A-Za-z0-9]*)?(?:_([A-Za-z][A-Za-z0-9_]*))?$/i);
    if (!m) return false;
    const qualifier = (m[3] || '').replace(/_/g, '').toLowerCase();
    const prefix = m[1].toLowerCase(), features = (m[2] || '').toLowerCase();
    return Number(version?.[1] || 1) === rule.version
        && (rule.features
            ? prefix + features + qualifier === rule.family + rule.features
            : prefix === rule.family && !qualifier);
}

function parseCatalog(markdown) {
    const entries = [];
    let headers = [], heading = '', lastEntries = [];
    let expectedTable = false, sectionRows = 0;
    const finishSection = () => {
        if (expectedTable && !sectionRows) throw new Error(`Retirement table missing or unrecognized: ${heading}`);
    };
    for (const line of markdown.split(/\r?\n/)) {
        if (/^#{1,6}\s/.test(line)) {
            finishSection();
            heading = plain(line);
            headers = [];
            lastEntries = [];
            expectedTable = /retired sizes/i.test(heading) && !/\bADH\b|dedicated host/i.test(heading);
            sectionRows = 0;
        }
        if (!line.trim().startsWith('|')) {
            if (line.trim() && lastEntries.length) {
                for (const entry of lastEntries) entry.notes += `\n${plain(line)}`;
            }
            continue;
        }
        const cells = line.trim().replace(/^\||\|$/g, '').split('|').map(s => s.trim());
        if (cells.some(c => plain(c).toLowerCase() === 'planned retirement date')) {
            headers = cells.map(c => plain(c).toLowerCase());
            continue;
        }
        if (cells.every(c => /^[-:\s]+$/.test(c))) continue;
        if (!headers.length) {
            if (expectedTable) throw new Error(`Unrecognized retirement table header: ${heading}`);
            continue;
        }
        if (cells.length !== headers.length) throw new Error('Retirement table column count changed');
        if (/\bADH\b|dedicated host/i.test(heading)) continue;
        const get = name => cells[headers.indexOf(name)];
        const label = get('series name');
        const guideCell = get('modernization guide');
        if (!label || !guideCell) throw new Error('Retirement table is missing required columns');
        if (!/^(announced|retired)$/i.test(plain(get('retirement status') || ''))) {
            throw new Error(`Unrecognized retirement status for ${label}`);
        }
        const link = guideCell.match(/\]\(([^)]+)\)/);
        if (!link) throw new Error(`Missing modernization link for ${label}`);
        const guideUrl = new URL(link[1], CATALOG_URL).href;
        assertLearnUrl(guideUrl);
        const entry = {
            label: plain(label), rules: seriesRules(label),
            retirementDate: dateOnly(get('planned retirement date')), guideUrl, notes: ''
        };
        entries.push(entry);
        lastEntries.push(entry);
        sectionRows++;
    }
    finishSection();
    if (!entries.length) throw new Error('No retirement rows found; Microsoft Learn format may have changed');
    return entries;
}

function assertLearnUrl(value) {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.hostname !== 'learn.microsoft.com'
        || !url.pathname.startsWith('/en-us/azure/virtual-machines/')) {
        throw new Error('Unexpected Microsoft Learn source URL');
    }
}

function assertArmUrl(value) {
    const url = new URL(value);
    if (url.origin !== ARM_ROOT) throw new Error('Unexpected Azure API continuation URL');
}

async function mapLimit(values, fn, limit = 4) {
    const results = new Array(values.length);
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(limit, values.length) }, async () => {
        while (next < values.length) {
            const index = next++;
            results[index] = await fn(values[index]);
        }
    }));
    return results;
}

function createClient(fetcher = fetch, budgetMs = 95000) {
    const end = Date.now() + budgetMs;
    return async (url, options = {}) => {
        for (let attempt = 0; attempt < 3; attempt++) {
            const remaining = end - Date.now();
            if (remaining <= 0) throw new Error('Lookup time budget exceeded; reduce subscription scope');
            const response = await fetcher(url, {
                ...options, redirect: 'error', signal: AbortSignal.timeout(Math.min(20000, remaining))
            });
            if (response.ok || response.status === 404) return response;
            if (attempt < 2 && (response.status === 429 || response.status >= 500)) {
                const retry = Number(response.headers.get('retry-after'));
                await new Promise(resolve => setTimeout(resolve, Math.min(5000, Math.max(1000, retry * 1000 || 1000))));
                continue;
            }
            throw new Error(`Source request failed (${response.status}): ${new URL(url).pathname}`);
        }
    };
}

async function learnPage(url, request) {
    assertLearnUrl(url);
    const target = new URL(url);
    target.search = '?accept=text/markdown';
    let response = await request(target.href);
    if (response.status === 404 && target.pathname.includes('/sizes/retirement/')) {
        // Some published links still use the pre-lifecycle documentation path.
        target.pathname = target.pathname.replace('/sizes/retirement/', '/sizes/lifecycle/retirement/');
        response = await request(target.href);
    }
    if (!response.ok) throw new Error(`Microsoft Learn page unavailable (${response.status}): ${target.pathname}`);
    if (!(response.headers.get('content-type') || '').includes('text/markdown')) {
        throw new Error(`Microsoft Learn did not return markdown: ${target.pathname}`);
    }
    const text = await response.text();
    if (!/^# /m.test(text)) throw new Error(`Microsoft Learn article body missing: ${target.pathname}`);
    return { text: text.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, ''), url: target.href.replace(/\?accept=text\/markdown$/, '') };
}

async function armJson(url, token, request, body) {
    assertArmUrl(url);
    const response = await request(url, {
        method: body ? 'POST' : 'GET',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        ...(body ? { body: JSON.stringify(body) } : {})
    });
    if (!response.ok) throw new Error(`Azure API resource unavailable (${response.status}): ${new URL(url).pathname}`);
    return response.json();
}

async function collection(url, token, request) {
    const values = [], seen = new Set();
    while (url) {
        if (seen.has(url)) throw new Error('Azure API returned a repeated continuation URL');
        seen.add(url);
        const page = await armJson(url, token, request);
        if (!Array.isArray(page.value)) throw new Error('Azure API collection is missing value');
        values.push(...page.value);
        url = page.nextLink;
    }
    return values;
}

async function inventory(subscriptions, token, request) {
    // Resource Graph silently ignores inaccessible subscriptions, so check each explicitly.
    await mapLimit(subscriptions, id => armJson(`${ARM_ROOT}/subscriptions/${id}?api-version=2022-12-01`, token, request));
    const resources = [], seen = new Set();
    let skipToken;
    do {
        const page = await armJson(`${ARM_ROOT}/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01`, token, request, {
            subscriptions, query: INVENTORY_QUERY,
            options: { resultFormat: 'objectArray', $top: 1000, ...(skipToken ? { $skipToken: skipToken } : {}) }
        });
        if (!Array.isArray(page.data)) throw new Error('Resource Graph response is missing data');
        resources.push(...page.data);
        skipToken = page.$skipToken;
        if (skipToken && seen.has(skipToken)) throw new Error('Resource Graph returned a repeated continuation token');
        if (skipToken) seen.add(skipToken);
        if ((page.resultTruncated === true || page.resultTruncated === 'true') && !skipToken) {
            throw new Error('Resource Graph truncated inventory without a continuation token');
        }
        if (!skipToken && Number(page.totalRecords) > resources.length) {
            throw new Error('Resource Graph omitted inventory records without a continuation token');
        }
    } while (skipToken);
    return resources;
}

function cutoffDate(today, months) {
    const cutoff = new Date(today);
    const day = cutoff.getUTCDate();
    cutoff.setUTCDate(1);
    cutoff.setUTCMonth(cutoff.getUTCMonth() + months);
    const lastDay = new Date(Date.UTC(cutoff.getUTCFullYear(), cutoff.getUTCMonth() + 1, 0)).getUTCDate();
    cutoff.setUTCDate(Math.min(day, lastDay));
    return cutoff.toISOString().slice(0, 10);
}

function englishDates(text) {
    return [...text.matchAll(/\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2})(?:st|nd|rd|th)?[,]?\s+(\d{4})\b/gi)]
        .map(m => {
            const date = new Date(`${m[1]} ${m[2]}, ${m[3]} 00:00:00 GMT`);
            if (!Number.isFinite(date.getTime())) throw new Error('Invalid regional retirement date in Microsoft Learn');
            return date.toISOString().slice(0, 10);
        });
}

const normalized = text => text.toLowerCase().replace(/[^a-z0-9]/g, '');

function mentionedLocations(sentence, locations) {
    let remaining = normalized(sentence);
    const mentioned = new Set();
    const aliases = locations.flatMap(loc => [loc.name, loc.displayName, loc.regionalDisplayName]
        .filter(Boolean).map(alias => ({ name: loc.name, alias: normalized(alias) })))
        .sort((a, b) => b.alias.length - a.alias.length);
    for (const { name, alias } of aliases) {
        if (remaining.includes(alias)) {
            mentioned.add(name.toLowerCase());
            remaining = remaining.replaceAll(alias, '|');
        }
    }
    return mentioned;
}

function resolveDeadline(entry, detail, location, locations) {
    const namedSeries = entry.notes.match(/\b[A-Z]+[a-z]*(?:_[a-z]+)?_?v\d+\b/g) || [];
    const entryNames = entry.rules.map(rule => normalized(rule.exact
        || `${rule.family}${rule.features}v${rule.version}`));
    const tableNotes = namedSeries.length && !namedSeries.some(series => entryNames.includes(normalized(series)))
        ? '' : entry.notes;
    const notes = `${tableNotes}\n${detail}`;
    const paragraphs = notes.split(/\n\s*\n/).filter(paragraph =>
        /extension|extended retirement|disregard.{0,100}retirement/i.test(paragraph)
        || ((/\b(region|cloud|government|21vianet)\b/i.test(paragraph)
            || mentionedLocations(paragraph, locations).size > 0)
            && /retirement.{0,100}(?:except|does not apply|doesn't apply)/i.test(paragraph)));
    let date = entry.retirementDate;
    for (const paragraph of paragraphs) {
        const sentences = paragraph.replace(/[*`]/g, '').split(/(?<=[.!?])\s+/);
        let understood = false, ambiguous = false;
        for (const sentence of sentences) {
            const dates = englishDates(sentence);
            const mentioned = mentionedLocations(sentence, locations);
            if (mentioned.size && /does not apply|doesn't apply|excluded/i.test(sentence)) {
                understood = true;
                if (mentioned.has(location.toLowerCase())) return { date, excluded: true, review: '' };
            } else if (dates.length && mentioned.size) {
                if (new Set(dates.filter(value => value !== entry.retirementDate)).size > 1) {
                    ambiguous = true;
                    continue;
                }
                understood = true;
                if (mentioned.has(location.toLowerCase())) {
                    date = [...dates, date].sort().at(-1);
                }
            }
        }
        if (!understood || ambiguous) return { date, review: 'Regional exception could not be resolved automatically; review the source.' };
    }
    return { date, review: '' };
}

function selectEntries(entries, sku) {
    const matches = entries.flatMap(entry => entry.rules.filter(rule => matchesSku(rule, sku))
        .map(rule => ({ entry, specificity: rule.specificity })));
    if (!matches.length) return [];
    const max = Math.max(...matches.map(match => match.specificity));
    return [...new Set(matches.filter(match => match.specificity === max).map(match => match.entry))];
}

async function scan(input, token, request, now = new Date()) {
    if (!input || !Array.isArray(input.subscriptionIds) || !input.subscriptionIds.length
        || input.subscriptionIds.some(id => typeof id !== 'string' || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(id))
        || !Number.isInteger(input.retirementHorizonMonths) || input.retirementHorizonMonths < 1 || input.retirementHorizonMonths > 60) {
        throw new Error('Expected subscriptionIds (GUID array) and retirementHorizonMonths (integer, 1-60)');
    }
    const subscriptions = [...new Set(input.subscriptionIds.map(id => id.toLowerCase()))];
    const today = new Date(now.toISOString().slice(0, 10));
    const horizon = cutoffDate(today, input.retirementHorizonMonths);
    const page = await learnPage(CATALOG_URL, request);
    const entries = parseCatalog(page.text);
    const resources = await inventory(subscriptions, token, request);
    const warnings = new Set();
    const matches = resources.flatMap(resource => {
        if (typeof resource.Sku !== 'string' || !resource.Sku) {
            warnings.add(`No scalar SKU is published for ${resource.id}; no retirement decision was made. Flexible VMSS member VMs are assessed separately.`);
            return [];
        }
        return selectEntries(entries, resource.Sku).filter(entry => entry.retirementDate <= horizon)
            .map(entry => ({ resource, entry }));
    });
    const guides = new Map(await mapLimit([...new Set(matches.map(match => match.entry.guideUrl))],
        async url => [url, await learnPage(url, request)]));
    const locations = new Map(await mapLimit([...new Set(matches.map(match => match.resource.SubscriptionId))],
        async id => [id, await collection(`${ARM_ROOT}/subscriptions/${id}/locations?api-version=2022-12-01`, token, request)]));
    const groups = [...new Set(matches.map(({ resource: r }) => `${r.SubscriptionId}/${r.Region.toLowerCase()}`))];
    const skus = new Map(await mapLimit(groups, async key => {
        const [id, region] = key.split('/');
        const query = encodeURIComponent(`location eq '${region}'`);
        const values = await collection(`${ARM_ROOT}/subscriptions/${id}/providers/Microsoft.Compute/skus?api-version=2021-07-01&$filter=${query}`, token, request);
        return [key, new Map(values.filter(sku => sku.resourceType === 'virtualMachines')
            .map(sku => [sku.name.toLowerCase(), sku]))];
    }));
    const rows = [], seen = new Set();
    for (const { resource, entry } of matches) {
        const guide = guides.get(entry.guideUrl);
        const deadline = resolveDeadline(entry, guide.text, resource.Region, locations.get(resource.SubscriptionId));
        if (deadline.excluded || (deadline.date > horizon && !deadline.review)) continue;
        const key = `${resource.id.toLowerCase()}/${deadline.date}/${guide.url}`;
        if (seen.has(key)) continue;
        seen.add(key);
        const sku = skus.get(`${resource.SubscriptionId}/${resource.Region.toLowerCase()}`).get(resource.Sku.toLowerCase());
        const capability = name => sku?.capabilities?.find(item => item.name === name)?.value;
        const days = Math.round((Date.parse(deadline.date) - today.getTime()) / DAY);
        if (!sku) warnings.add('Some source SKUs are absent from the live Compute catalog; specifications are unavailable, not inferred.');
        if (deadline.review) warnings.add(deadline.review);
        rows.push({
            ...resource,
            Status: deadline.review ? 'Review regional scope' : days <= 0 ? 'Retired' : `Retires in ${days} day${days === 1 ? '' : 's'}`,
            RetirementDate: deadline.date,
            PublishedSeries: entry.label,
            vCPUs: capability('vCPUsAvailable') || capability('vCPUs') || 'Unavailable',
            MemoryGB: capability('MemoryGB') || 'Unavailable',
            MigrationGuidance: guide.url,
            ScopeNote: deadline.review || (deadline.date !== entry.retirementDate ? 'Regional extension from Microsoft Learn' : 'Published retirement date')
        });
    }
    rows.sort((a, b) => a.RetirementDate.localeCompare(b.RetirementDate) || a.id.localeCompare(b.id));
    return {
        resources: rows.slice(0, 1000), totalFindings: rows.length, scannedResources: resources.length,
        scannedSubscriptions: subscriptions.length, catalogEntries: entries.length,
        retrievedAt: now.toISOString(), source: CATALOG_URL, warnings: [...warnings]
    };
}

async function handler(context, req) {
    try {
        if (!process.env.IDENTITY_ENDPOINT || !process.env.IDENTITY_HEADER) {
            throw new Error('Function managed identity is not configured');
        }
        const request = createClient();
        const identity = new URL(process.env.IDENTITY_ENDPOINT);
        identity.searchParams.set('api-version', '2019-08-01');
        identity.searchParams.set('resource', `${ARM_ROOT}/`);
        const response = await request(identity.href, { headers: { 'X-IDENTITY-HEADER': process.env.IDENTITY_HEADER } });
        if (!response.ok) throw new Error(`Managed identity token request failed (${response.status})`);
        const credentials = await response.json();
        if (!credentials.access_token) throw new Error('Managed identity token response has no access_token');
        const result = await scan(req.body, credentials.access_token, request);
        context.res = { status: 200, headers: { 'Content-Type': 'application/json' }, body: result };
    } catch (error) {
        context.log.error(error.message);
        context.res = { status: 502, headers: { 'Content-Type': 'application/json' }, body: { error: 'RetirementLookupFailed', message: error.message } };
    }
}

module.exports = handler;
module.exports.internals = {
    parseCatalog, seriesRules, matchesSku, dateOnly, cutoffDate, resolveDeadline,
    selectEntries, createClient, learnPage, collection, inventory, scan, CATALOG_URL
};
