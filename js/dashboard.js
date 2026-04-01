const BADGE_LABELS = {
    PartitionDisk: 'P', DownloadImage: 'D', ApplyImage: 'A', SetBootloader: 'B',
    InjectDrivers: 'I', InjectOemDrivers: 'O', ApplyAutopilot: 'AP',
    StageCCMSetup: 'S', CustomizeOOBE: 'C', RunPostScripts: 'R',
    SetComputerName: 'N', SetRegionalSettings: 'L', ImportAutopilot: 'IA'
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
        '<span class="ts-card-stat"><span class="ts-card-stat-icon">&#128203;</span> ' + totalSteps + ' step' + (totalSteps !== 1 ? 's' : '') + '</span>' +
        '<span class="ts-card-stat"><span class="ts-card-stat-icon">&#9989;</span> ' + enabledSteps + ' enabled</span>' +
        (disabledSteps > 0 ? '<span class="ts-card-stat"><span class="ts-card-stat-icon">&#10060;</span> ' + disabledSteps + ' disabled</span>' : '') +
        '</div>';

    /* Mini badges */
    var badgesHtml = '<div class="ts-card-badges">';
    if (ts.steps) {
        ts.steps.forEach(function (step) {
            var label = BADGE_LABELS[step.type] || '?';
            var cls = step.enabled === false ? ' disabled' : '';
            badgesHtml += '<span class="ts-mini-badge' + cls + '" data-type="' + escapeHtml(step.type) + '" title="' + escapeHtml(step.name) + '">' + label + '</span>';
        });
    }
    badgesHtml += '</div>';

    /* Actions */
    var actionsHtml = '<div class="ts-card-actions">' +
        '<button class="ts-card-action primary" data-action="open">&#9998; Open in Editor</button>' +
        '<button class="ts-card-action" data-action="download">&#11015; Download</button>' +
        '<button class="ts-card-action" data-action="duplicate">&#128203; Duplicate</button>' +
        (storageKey ? '<button class="ts-card-action" data-action="remove" title="Remove from recently opened">&#128465; Remove</button>' : '') +
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
        window.location.href = 'Editor/index.html?ts=' + encodeURIComponent(source);
    } else {
        window.location.href = 'Editor/index.html?new=1';
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

/** Load the default task sequence and display. */
function loadDashboard() {
    var grid = document.getElementById('tsGrid');
    var skeleton = document.getElementById('loadingSkeleton');

    fetch('TaskSequence/default.json')
        .then(function (r) {
            if (!r.ok) throw new Error(r.statusText);
            return r.json();
        })
        .then(function (ts) {
            if (skeleton) skeleton.remove();
            var card = createTsCard(ts, 'default', null);
            grid.insertBefore(card, grid.firstChild);
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
