/* ── Step type display names ────────────────────────────────────────── */
const STEP_DISPLAY_NAMES = {
    PartitionDisk: 'Partition Disk', DownloadImage: 'Download Image', ApplyImage: 'Apply Image',
    SetBootloader: 'Bootloader', InjectDrivers: 'Inject Drivers', InjectOemDrivers: 'OEM Drivers',
    ApplyAutopilot: 'Autopilot Config', StageCCMSetup: 'ConfigMgr', CustomizeOOBE: 'OOBE',
    RunPostScripts: 'Post Scripts', SetComputerName: 'Computer Name',
    SetRegionalSettings: 'Regional', ImportAutopilot: 'Import Autopilot'
};

/* ── Step type → category mapping ──────────────────────────────────── */
const STEP_CATEGORIES = {
    PartitionDisk: 'Disk & Image', DownloadImage: 'Disk & Image', ApplyImage: 'Disk & Image',
    SetBootloader: 'Disk & Image', InjectDrivers: 'Drivers', InjectOemDrivers: 'Drivers',
    ImportAutopilot: 'Provisioning', ApplyAutopilot: 'Provisioning', StageCCMSetup: 'Provisioning',
    SetComputerName: 'Configuration', SetRegionalSettings: 'Configuration',
    CustomizeOOBE: 'Finalization', RunPostScripts: 'Finalization'
};

const CATEGORY_ICONS = {
    'Disk & Image':   '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="3"/></svg>',
    'Drivers':        '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="7" width="20" height="10" rx="2"/><circle cx="8" cy="12" r="1"/><circle cx="16" cy="12" r="1"/></svg>',
    'Provisioning':   '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 17l10 5 10-5"/><path d="M2 12l10 5 10-5"/></svg>',
    'Configuration':  '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/></svg>',
    'Finalization':   '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>'
};

const CATEGORY_COLORS = {
    'Disk & Image': '#2563eb', 'Drivers': '#db2777', 'Provisioning': '#0891b2',
    'Configuration': '#d97706', 'Finalization': '#65a30d'
};

/* ── SVG icon helpers ──────────────────────────────────────────────── */
var ICONS = {
    steps:     '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></svg>',
    enabled:   '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#22c55e" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>',
    disabled:  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#ef4444" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>',
    edit:      '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>',
    download:  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>',
    duplicate: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>',
    remove:    '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>'
};

var MAX_RECENT_ITEMS = 10;
var MAX_FILENAME_LENGTH = 60;
var SESSION_PREFIX = 'session:';

function escapeHtml(str) {
    var d = document.createElement('div');
    d.appendChild(document.createTextNode(str));
    return d.innerHTML;
}

/** Build a task sequence card element. */
function createTsCard(ts, source, storageKey) {
    var totalSteps = ts.steps ? ts.steps.length : 0;
    var enabledSteps = ts.steps ? ts.steps.filter(function (s) { return s.enabled !== false; }).length : 0;
    var disabledSteps = totalSteps - enabledSteps;

    var card = document.createElement('div');
    card.className = 'ts-card';

    /* Card header */
    var headerHtml = '<div class="ts-card-header">' +
        '<div class="ts-card-name">' + escapeHtml(ts.name || 'Untitled Task Sequence') + '</div>' +
        (ts.version ? '<span class="ts-card-version">v' + escapeHtml(ts.version) + '</span>' : '') +
        '</div>';

    /* Description */
    var descHtml = '<div class="ts-card-desc">' + escapeHtml(ts.description || 'No description') + '</div>';

    /* Meta stats */
    var metaHtml = '<div class="ts-card-meta">' +
        '<span class="ts-card-stat"><span class="ts-card-stat-icon">' + ICONS.steps + '</span>' + totalSteps + ' step' + (totalSteps !== 1 ? 's' : '') + '</span>' +
        '<span class="ts-card-stat"><span class="ts-card-stat-icon">' + ICONS.enabled + '</span>' + enabledSteps + ' enabled</span>' +
        (disabledSteps > 0 ? '<span class="ts-card-stat"><span class="ts-card-stat-icon">' + ICONS.disabled + '</span>' + disabledSteps + ' disabled</span>' : '') +
        '</div>';

    /* Category summary pills */
    var badgesHtml = '<div class="ts-card-badges">';
    if (ts.steps && ts.steps.length > 0) {
        var catCounts = {};
        ts.steps.forEach(function (step) {
            var cat = STEP_CATEGORIES[step.type] || 'Other';
            if (!catCounts[cat]) catCounts[cat] = 0;
            catCounts[cat]++;
        });
        Object.keys(catCounts).forEach(function (cat) {
            var icon = CATEGORY_ICONS[cat] || '';
            var color = CATEGORY_COLORS[cat] || '#71717a';
            badgesHtml += '<span class="ts-category-pill" style="--pill-color:' + color + '" title="' + escapeHtml(cat) + ': ' + catCounts[cat] + ' step' + (catCounts[cat] !== 1 ? 's' : '') + '">' + icon + ' ' + escapeHtml(cat) + ' <span class="ts-pill-count">' + catCounts[cat] + '</span></span>';
        });
    }
    badgesHtml += '</div>';

    /* Actions */
    var actionsHtml = '<div class="ts-card-actions">' +
        '<button class="ts-card-action primary" data-action="open">' + ICONS.edit + ' Open in Editor</button>' +
        '<button class="ts-card-action" data-action="download">' + ICONS.download + ' Download</button>' +
        '<button class="ts-card-action" data-action="duplicate">' + ICONS.duplicate + ' Duplicate</button>' +
        (storageKey ? '<button class="ts-card-action" data-action="remove" title="Remove from recently opened">' + ICONS.remove + ' Remove</button>' : '') +
        '</div>';

    card.innerHTML = headerHtml + descHtml + metaHtml + badgesHtml + actionsHtml;

    /* Click on card body opens editor */
    card.addEventListener('click', function (e) {
        if (e.target.closest('.ts-card-actions')) return;
        openEditor(source);
    });

    /* Action buttons */
    card.querySelectorAll('[data-action]').forEach(function (btn) {
        btn.addEventListener('click', function (e) {
            e.stopPropagation();
            var action = btn.getAttribute('data-action');
            if (action === 'open') {
                openEditor(source);
            } else if (action === 'download') {
                downloadTs(ts);
            } else if (action === 'duplicate') {
                duplicateTs(ts);
            } else if (action === 'remove' && storageKey) {
                removeRecent(storageKey);
            }
        });
    });

    return card;
}

/** Create the "New Task Sequence" card. */
function createNewCard() {
    var card = document.createElement('div');
    card.className = 'ts-card ts-card-new';
    card.innerHTML =
        '<div class="ts-card-new-icon">&#43;</div>' +
        '<div class="ts-card-new-label">Create New Task Sequence</div>' +
        '<div class="ts-card-new-hint">Start from scratch or import a JSON file</div>';
    card.addEventListener('click', function () { openEditor(); });
    return card;
}

/** Navigate to the Editor. */
function openEditor(source) {
    if (source) {
        window.location.href = 'src/web/editor/index.html?ts=' + encodeURIComponent(source);
    } else {
        window.location.href = 'src/web/editor/index.html?new=1';
    }
}

/** Download a task sequence as JSON. */
function downloadTs(ts) {
    var json = JSON.stringify(ts, null, 2);
    var blob = new Blob([json], { type: 'application/json' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    var safeName = (ts.name || 'tasksequence').replace(/[^a-zA-Z0-9_-]/g, '_').substring(0, MAX_FILENAME_LENGTH);
    a.download = safeName + '.json';
    a.click();
    URL.revokeObjectURL(a.href);
}

/** Duplicate a task sequence into recently opened. */
function duplicateTs(ts) {
    var copy = JSON.parse(JSON.stringify(ts));
    copy.name = (copy.name || 'Task Sequence') + ' (Copy)';
    saveToRecent(copy);
    loadRecentSequences();
}

/** Save a task sequence to localStorage recent list. */
function saveToRecent(ts) {
    var recents = JSON.parse(localStorage.getItem('nova_recent_ts') || '[]');
    var key = 'ts_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
    recents.unshift({ key: key, data: ts, timestamp: Date.now() });
    if (recents.length > MAX_RECENT_ITEMS) recents = recents.slice(0, MAX_RECENT_ITEMS);
    localStorage.setItem('nova_recent_ts', JSON.stringify(recents));
    /* Also store the actual data for editor retrieval */
    sessionStorage.setItem(key, JSON.stringify(ts));
    return key;
}

/** Remove a recently opened task sequence. */
function removeRecent(key) {
    var recents = JSON.parse(localStorage.getItem('nova_recent_ts') || '[]');
    recents = recents.filter(function (r) { return r.key !== key; });
    localStorage.setItem('nova_recent_ts', JSON.stringify(recents));
    sessionStorage.removeItem(key);
    loadRecentSequences();
}

/** Load and display recently opened task sequences. */
function loadRecentSequences() {
    var recents = JSON.parse(localStorage.getItem('nova_recent_ts') || '[]');
    var section = document.getElementById('recentSection');
    var grid = document.getElementById('recentGrid');

    if (recents.length === 0) {
        section.classList.add('hidden');
        return;
    }

    section.classList.remove('hidden');
    grid.innerHTML = '';
    recents.forEach(function (entry) {
        if (entry.data) {
            /* Store data in sessionStorage so editor can load it */
            sessionStorage.setItem(entry.key, JSON.stringify(entry.data));
            var card = createTsCard(entry.data, SESSION_PREFIX + entry.key, entry.key);
            grid.appendChild(card);
        }
    });
}

/** Load all available task sequences and display. */
function loadDashboard() {
    var grid = document.getElementById('tsGrid');
    var skeleton = document.getElementById('loadingSkeleton');

    fetch('resources/task-sequence/index.json')
        .then(function (r) {
            if (!r.ok) throw new Error(r.statusText);
            return r.json();
        })
        .then(function (files) {
            var fetches = files.map(function (file) {
                return fetch('resources/task-sequence/' + file)
                    .then(function (r) {
                        if (!r.ok) throw new Error(r.statusText);
                        return r.json();
                    })
                    .then(function (ts) {
                        return { file: file, data: ts };
                    })
                    .catch(function () {
                        /* Skip files that fail to load */
                        return null;
                    });
            });
            return Promise.all(fetches);
        })
        .then(function (results) {
            if (skeleton) skeleton.remove();
            results.forEach(function (entry) {
                if (!entry) return;
                var source = entry.file === 'default.json' ? 'default' : entry.file;
                var card = createTsCard(entry.data, source, null);
                grid.appendChild(card);
            });
            grid.appendChild(createNewCard());
        })
        .catch(function () {
            if (skeleton) skeleton.remove();
            grid.appendChild(createNewCard());
        });

    loadRecentSequences();
}

/* ── Import handler ─────────────────────────────────────────────── */
document.getElementById('fileInput').addEventListener('change', function (e) {
    var file = e.target.files[0];
    if (!file) return;
    var reader = new FileReader();
    reader.onload = function (ev) {
        try {
            var data = JSON.parse(ev.target.result);
            if (!data.steps || !Array.isArray(data.steps)) throw new Error('Invalid task sequence: missing steps array');
            var key = saveToRecent(data);
            openEditor(SESSION_PREFIX + key);
        } catch (err) {
            alert('Failed to import task sequence:\n' + err.message);
        }
    };
    reader.readAsText(file);
    e.target.value = '';
});

/* ── Button handlers (replaces inline onclick) ─────────────────── */
document.getElementById('btnImport').addEventListener('click', function () {
    document.getElementById('fileInput').click();
});
document.getElementById('btnNew').addEventListener('click', function () {
    openEditor();
});

/* ── Init ───────────────────────────────────────────────────────── */
loadDashboard();
