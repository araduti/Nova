/* ── Constants ──────────────────────────────────────────────────── */
var STORAGE_KEY = 'nova_deploy_history';
var ACTIVE_KEY  = 'nova_active_deploys';
var ALERTS_KEY  = 'nova_alert_config';

/* GitHub repo for fetching deployment data pushed by the engine */
var GH_OWNER  = 'araduti';
var GH_REPO   = 'Nova';
var GH_BRANCH = 'main';
var GH_API    = 'https://api.github.com';
var REFRESH_INTERVAL = 30000; /* poll every 30 s */
var STALE_THRESHOLD  = 4 * 60 * 60 * 1000; /* 4 hours in ms — deployments older than this are flagged stale */
var ABANDON_THRESHOLD = 24 * 60 * 60 * 1000; /* 24 hours in ms — cached entries older than this are auto-purged */

/* Entra ID → GitHub token exchange state (loaded from config/auth.json) */
var authConfig      = null;  /* populated by loadAuthConfig() */
var cachedGhToken   = null;  /* GitHub token obtained via Entra exchange */
var ghTokenExpiry   = 0;     /* Unix-ms when cachedGhToken expires */

/* ── Utility helpers ───────────────────────────────────────────── */
function escapeHtml(str) {
    var d = document.createElement('div');
    d.appendChild(document.createTextNode(str));
    return d.innerHTML;
}

function formatDuration(ms) {
    if (!ms || ms <= 0) return '—';
    var s = Math.floor(ms / 1000);
    var m = Math.floor(s / 60);
    s = s % 60;
    if (m > 0) return m + 'm ' + s + 's';
    return s + 's';
}

function formatDate(ts) {
    if (!ts) return '—';
    var d = new Date(ts);
    return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function dayLabel(ts) {
    var d = new Date(ts);
    return d.toLocaleDateString(undefined, { weekday: 'short' });
}

/* ── Data access ───────────────────────────────────────────────── */
function getHistory() {
    try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]'); }
    catch (e) { return []; }
}

function saveHistory(records) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(records));
}

function getActiveDeployments() {
    try { return JSON.parse(localStorage.getItem(ACTIVE_KEY) || '[]'); }
    catch (e) { return []; }
}

function saveActiveDeployments(records) {
    localStorage.setItem(ACTIVE_KEY, JSON.stringify(records));
}

/* ── Auth config & Entra → GitHub token exchange ───────────────── */
/*  Loads config/auth.json and uses the OAuth proxy's
    /api/token-exchange endpoint to convert an Entra ID session
    token into a scoped GitHub installation token.  This lets the
    dashboard make authenticated GitHub API calls (5 000 req/hr)
    without requiring a separate GitHub PAT.
    If the exchange is unavailable the dashboard falls back to
    unauthenticated reads (60 req/hr, fine for public repos).     */

function loadAuthConfig() {
    var url = 'https://raw.githubusercontent.com/' + GH_OWNER + '/' + GH_REPO + '/' + GH_BRANCH + '/config/auth.json';
    return fetch(url)
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (cfg) { authConfig = cfg; })
        .catch(function () { authConfig = null; });
}

function exchangeEntraToken(entraToken) {
    if (!authConfig || !authConfig.githubOAuthProxy) {
        return Promise.resolve(null);
    }
    return fetch(authConfig.githubOAuthProxy + '/api/token-exchange', {
        method: 'POST',
        headers: {
            'Authorization': 'Bearer ' + entraToken,
            'Content-Type': 'application/json'
        }
    })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (data) {
        if (data && data.token) {
            cachedGhToken = data.token;
            ghTokenExpiry = data.expires_at
                ? new Date(data.expires_at).getTime()
                : Date.now() + 55 * 60 * 1000; /* 55 min — 5-min safety buffer before typical 60-min expiry */
            return data.token;
        }
        return null;
    })
    .catch(function () { return null; });
}

function getGitHubHeaders() {
    var headers = { Accept: 'application/vnd.github.v3+json' };
    if (cachedGhToken && Date.now() < ghTokenExpiry) {
        headers['Authorization'] = 'Bearer ' + cachedGhToken;
    }
    return headers;
}

/* ── GitHub data fetch ─────────────────────────────────────────── */
/*  Fetches per-device JSON files pushed by the engine via the
    GitHub Contents API.  This bridges the gap between the engine
    (which writes files atomically with PUT) and the dashboard
    (which reads them here).  Each device gets its own file so
    concurrent deployments never collide or block each other.
    When an Entra-derived GitHub token is available, requests are
    authenticated (5 000 req/hr); otherwise falls back to
    unauthenticated reads (60 req/hr, fine for public repos).     */

function fetchGitHubDir(dirPath) {
    var url = GH_API + '/repos/' + GH_OWNER + '/' + GH_REPO + '/contents/' + dirPath + '?ref=' + GH_BRANCH;
    return fetch(url, { headers: getGitHubHeaders() })
        .then(function (r) { return r.ok ? r.json() : null; })
        .catch(function () { return null; });
}

function fetchGitHubFile(downloadUrl) {
    return fetch(downloadUrl, { headers: getGitHubHeaders() })
        .then(function (r) { return r.ok ? r.json() : null; })
        .catch(function () { return null; });
}

function mergeById(existing, incoming) {
    var map = {};
    existing.forEach(function (r) { map[r.id] = r; });
    incoming.forEach(function (r) { map[r.id] = r; });
    return Object.keys(map).map(function (k) { return map[k]; });
}

function fetchDeploymentReports() {
    return fetchGitHubDir('deployments/reports').then(function (files) {
        if (!Array.isArray(files) || files.length === 0) return;
        var promises = files
            .filter(function (f) { return f.name && f.name.endsWith('.json'); })
            .map(function (f) { return fetchGitHubFile(f.download_url); });
        return Promise.all(promises).then(function (reports) {
            var valid = reports.filter(function (r) { return r && r.id; });
            if (valid.length > 0) {
                var merged = mergeById(getHistory(), valid);
                saveHistory(merged);
            }
        });
    });
}

function fetchActiveDeployments() {
    return fetchGitHubDir('deployments/active').then(function (files) {
        if (!Array.isArray(files)) return;
        var jsonFiles = files.filter(function (f) { return f.name && f.name.endsWith('.json'); });
        if (jsonFiles.length === 0) {
            /* No active files on GitHub — clear stale active entries */
            saveActiveDeployments([]);
            return;
        }
        var promises = jsonFiles
            .map(function (f) { return fetchGitHubFile(f.download_url); });
        return Promise.all(promises).then(function (records) {
            var valid = records.filter(function (r) { return r && r.id; });
            saveActiveDeployments(valid);
        });
    });
}

function refreshFromGitHub() {
    Promise.all([fetchDeploymentReports(), fetchActiveDeployments()])
        .then(function () { renderAll(); })
        .catch(function () {
            /* Network or rate-limit — use cached data but still apply
               staleness filtering so orphaned entries don't persist
               indefinitely when the dashboard can't reach GitHub. */
            var cached = getActiveDeployments();
            if (cached.length > 0) {
                var filtered = cached.filter(function (d) {
                    return d.startedAt && (Date.now() - d.startedAt) < ABANDON_THRESHOLD;
                });
                if (filtered.length !== cached.length) {
                    saveActiveDeployments(filtered);
                }
            }
            renderAll();
        });
}

function getAlertConfig() {
    var defaults = {
        teams:  { enabled: false, webhook: '', onSuccess: true, onFailure: true },
        slack:  { enabled: false, webhook: '', onSuccess: true, onFailure: true },
        email:  { enabled: false, smtp: '', port: 587, from: '', to: '', onSuccess: true, onFailure: true }
    };
    try {
        var saved = JSON.parse(localStorage.getItem(ALERTS_KEY));
        if (saved) return saved;
    } catch (e) { /* use defaults */ }
    return defaults;
}

/* ── Tab switching ─────────────────────────────────────────────── */
document.querySelectorAll('.mon-tab').forEach(function (tab) {
    tab.addEventListener('click', function () {
        document.querySelectorAll('.mon-tab').forEach(function (t) { t.classList.remove('active'); });
        document.querySelectorAll('.mon-tab-panel').forEach(function (p) { p.classList.remove('active'); });
        tab.classList.add('active');
        var panel = document.getElementById('tab-' + tab.getAttribute('data-tab'));
        if (panel) panel.classList.add('active');
    });
});

/* ── Summary cards ─────────────────────────────────────────────── */
function renderSummary() {
    var history = getHistory();
    var active  = getActiveDeployments();
    var total   = history.length;
    var success = history.filter(function (r) { return r.status === 'success'; }).length;
    var failed  = history.filter(function (r) { return r.status === 'failed'; }).length;
    var rate    = total > 0 ? Math.round((success / total) * 100) : 0;

    var durations = history
        .filter(function (r) { return r.duration > 0; })
        .map(function (r) { return r.duration; });
    var avgDuration = durations.length > 0
        ? Math.round(durations.reduce(function (a, b) { return a + b; }, 0) / durations.length)
        : 0;

    var grid = document.getElementById('summaryGrid');
    grid.innerHTML =
        '<div class="summary-card">' +
            '<div class="summary-card-label">Active</div>' +
            '<div class="summary-card-value accent">' + active.length + '</div>' +
            '<div class="summary-card-sub">deployment' + (active.length !== 1 ? 's' : '') + ' in progress</div>' +
        '</div>' +
        '<div class="summary-card">' +
            '<div class="summary-card-label">Total Deployments</div>' +
            '<div class="summary-card-value">' + total + '</div>' +
            '<div class="summary-card-sub">all time</div>' +
        '</div>' +
        '<div class="summary-card">' +
            '<div class="summary-card-label">Success Rate</div>' +
            '<div class="summary-card-value ' + (rate >= 80 ? 'success' : rate >= 50 ? 'warning' : 'danger') + '">' + rate + '%</div>' +
            '<div class="summary-card-sub">' + success + ' succeeded, ' + failed + ' failed</div>' +
        '</div>' +
        '<div class="summary-card">' +
            '<div class="summary-card-label">Avg Duration</div>' +
            '<div class="summary-card-value">' + formatDuration(avgDuration) + '</div>' +
            '<div class="summary-card-sub">per deployment</div>' +
        '</div>';
}

/* ── Active deployments panel ──────────────────────────────────── */
function isDeploymentStale(dep) {
    if (!dep.startedAt) return false;
    return (Date.now() - dep.startedAt) > STALE_THRESHOLD;
}

function dismissStaleDeployment(deviceId) {
    var active = getActiveDeployments().filter(function (d) { return d.id !== deviceId; });
    saveActiveDeployments(active);
    renderAll();
}

function renderActiveDeployments() {
    var active = getActiveDeployments();
    var container = document.getElementById('activeDeployments');

    if (active.length === 0) {
        container.innerHTML =
            '<div class="deploy-empty">' +
                '<div class="deploy-empty-icon">&#128203;</div>' +
                '<p>No active deployments. Deployment status will appear here in real time when devices are being imaged.</p>' +
                '<p style="margin-top:8px"><button type="button" class="diag-link">&#128295; Troubleshoot connection</button></p>' +
            '</div>';
        return;
    }

    container.innerHTML = '';
    active.forEach(function (dep) {
        var progress = dep.progress || 0;
        var stale = isDeploymentStale(dep);
        var statusCls = dep.status === 'failed' ? 'failed' : (stale ? 'stale' : (progress >= 100 ? 'success' : 'running'));
        var statusLabel = stale ? 'Stale' : (statusCls === 'running' ? 'In Progress' : (statusCls === 'success' ? 'Complete' : 'Failed'));

        var staleBanner = '';
        if (stale) {
            var elapsed = Date.now() - dep.startedAt;
            var hours = Math.floor(elapsed / 3600000);
            var mins  = Math.floor((elapsed % 3600000) / 60000);
            var elapsedStr = hours > 0 ? hours + 'h ' + mins + 'm' : mins + 'm';
            staleBanner =
                '<div class="deploy-stale-banner">' +
                    '<span>&#9888; Running for ' + elapsedStr + ' — this deployment may have completed or failed without updating its status.</span>' +
                    '<button type="button" class="deploy-dismiss-btn" data-device-id="' + escapeHtml(dep.id || '') + '">Dismiss</button>' +
                '</div>';
        }

        var html =
            '<div class="deploy-card' + (stale ? ' stale' : '') + '">' +
                '<div class="deploy-card-header">' +
                    '<div>' +
                        '<div class="deploy-card-name">' + escapeHtml(dep.deviceName || 'Unknown Device') + '</div>' +
                        '<div class="deploy-card-device">' + escapeHtml(dep.taskSequence || 'Default Task Sequence') + '</div>' +
                    '</div>' +
                    '<span class="deploy-status ' + statusCls + '">' +
                        '<span class="deploy-status-dot"></span>' +
                        statusLabel +
                    '</span>' +
                '</div>' +
                '<div class="deploy-progress-bar">' +
                    '<div class="deploy-progress-fill" style="width:' + Math.min(progress, 100) + '%"></div>' +
                '</div>' +
                '<div class="deploy-card-step">' + escapeHtml(dep.currentStep || 'Initializing...') + '</div>' +
                '<div class="deploy-card-meta">' +
                    '<span>Started: ' + formatDate(dep.startedAt) + '</span>' +
                    '<span>Progress: ' + progress + '%</span>' +
                '</div>' +
                staleBanner +
            '</div>';

        var card = document.createElement('div');
        card.innerHTML = html;
        container.appendChild(card.firstChild);
    });
}

/* ── Bar chart — deployments per day ───────────────────────────── */
function renderBarChart() {
    var history = getHistory();
    var container = document.getElementById('barChart');

    // Last 7 days
    var days = [];
    for (var i = 6; i >= 0; i--) {
        var d = new Date();
        d.setHours(0, 0, 0, 0);
        d.setDate(d.getDate() - i);
        days.push({ date: d.getTime(), label: dayLabel(d), success: 0, failed: 0 });
    }

    history.forEach(function (r) {
        var rDate = new Date(r.startedAt);
        rDate.setHours(0, 0, 0, 0);
        var rTime = rDate.getTime();
        for (var j = 0; j < days.length; j++) {
            if (days[j].date === rTime) {
                if (r.status === 'success') days[j].success++;
                else days[j].failed++;
                break;
            }
        }
    });

    var maxVal = Math.max.apply(null, days.map(function (d) { return d.success + d.failed; }));
    if (maxVal < 1) maxVal = 1;

    var html = '';
    days.forEach(function (d) {
        var total = d.success + d.failed;
        var successH = total > 0 ? Math.max((d.success / maxVal) * 140, d.success > 0 ? 8 : 0) : 0;
        var failH    = total > 0 ? Math.max((d.failed / maxVal) * 140, d.failed > 0 ? 8 : 0) : 0;

        html += '<div class="bar-col">';
        if (total > 0) {
            html += '<div class="bar-value">' + total + '</div>';
        }
        if (d.failed > 0) {
            html += '<div class="bar-fill danger" style="height:' + failH + 'px" title="' + d.failed + ' failed"></div>';
        }
        if (d.success > 0) {
            html += '<div class="bar-fill success" style="height:' + successH + 'px" title="' + d.success + ' succeeded"></div>';
        }
        if (total === 0) {
            html += '<div class="bar-fill" style="height:4px;background:var(--border)"></div>';
        }
        html += '<div class="bar-label">' + d.label + '</div>';
        html += '</div>';
    });

    container.innerHTML = html;
}

/* ── Donut chart — success rate ────────────────────────────────── */
function renderDonutChart() {
    var history = getHistory();
    var container = document.getElementById('donutChart');

    var success = history.filter(function (r) { return r.status === 'success'; }).length;
    var failed  = history.filter(function (r) { return r.status === 'failed'; }).length;
    var total   = success + failed;

    if (total === 0) {
        container.innerHTML = '<div class="deploy-empty" style="padding:20px"><p>No deployment data yet.</p><p style="margin-top:8px"><button type="button" class="diag-link">&#128295; Troubleshoot connection</button></p></div>';
        return;
    }

    var rate = Math.round((success / total) * 100);
    var radius = 42;
    var circumference = 2 * Math.PI * radius;
    var successArc = (success / total) * circumference;
    var failArc    = (failed / total) * circumference;

    container.innerHTML =
        '<svg class="donut-svg" viewBox="0 0 120 120">' +
            '<circle cx="60" cy="60" r="' + radius + '" fill="none" stroke="rgba(224,62,62,0.3)" stroke-width="12" />' +
            '<circle cx="60" cy="60" r="' + radius + '" fill="none" stroke="#2b8a3e" stroke-width="12" ' +
                'stroke-dasharray="' + successArc + ' ' + (circumference - successArc) + '" ' +
                'stroke-dashoffset="' + (circumference * 0.25) + '" ' +
                'stroke-linecap="round" />' +
            '<text x="60" y="56" text-anchor="middle" class="donut-center-text">' + rate + '%</text>' +
            '<text x="60" y="72" text-anchor="middle" class="donut-center-sub">success</text>' +
        '</svg>' +
        '<div class="donut-legend">' +
            '<div class="donut-legend-item">' +
                '<span class="donut-legend-dot" style="background:#2b8a3e"></span>' +
                'Succeeded' +
                '<span class="donut-legend-value">' + success + '</span>' +
            '</div>' +
            '<div class="donut-legend-item">' +
                '<span class="donut-legend-dot" style="background:#e03e3e"></span>' +
                'Failed' +
                '<span class="donut-legend-value">' + failed + '</span>' +
            '</div>' +
            '<div class="donut-legend-item">' +
                '<span class="donut-legend-dot" style="background:var(--text-muted)"></span>' +
                'Total' +
                '<span class="donut-legend-value">' + total + '</span>' +
            '</div>' +
        '</div>';
}

/* ── Common errors panel ───────────────────────────────────────── */
function renderErrors() {
    var history = getHistory();
    var container = document.getElementById('errorList');
    var errorMap = {};

    history.forEach(function (r) {
        if (r.status === 'failed' && r.error) {
            var label = r.failedStep ? r.failedStep + ': ' + r.error : r.error;
            var key = label.length > 80 ? label.substring(0, 80) + '…' : label;
            errorMap[key] = (errorMap[key] || 0) + 1;
        }
    });

    var errors = Object.keys(errorMap).map(function (k) {
        return { name: k, count: errorMap[k] };
    }).sort(function (a, b) { return b.count - a.count; }).slice(0, 8);

    if (errors.length === 0) {
        container.innerHTML = '<div class="deploy-empty" style="padding:20px"><p>No errors recorded.</p><p style="margin-top:8px"><button type="button" class="diag-link">&#128295; Troubleshoot connection</button></p></div>';
        return;
    }

    var maxCount = errors[0].count;
    var html = '';
    errors.forEach(function (e) {
        var pct = Math.round((e.count / maxCount) * 100);
        html += '<div class="error-item">' +
            '<span class="error-item-name">' + escapeHtml(e.name) + '</span>' +
            '<span class="error-item-count">' + e.count + '</span>' +
            '<span class="error-item-bar"><span class="error-item-bar-fill" style="width:' + pct + '%"></span></span>' +
            '</div>';
    });

    container.innerHTML = html;
}

/* ── Avg deployment time chart ─────────────────────────────────── */
function renderAvgTimeChart() {
    var history = getHistory();
    var container = document.getElementById('avgTimeChart');

    // Group by day (last 7 days)
    var days = [];
    for (var i = 6; i >= 0; i--) {
        var d = new Date();
        d.setHours(0, 0, 0, 0);
        d.setDate(d.getDate() - i);
        days.push({ date: d.getTime(), label: dayLabel(d), totalMs: 0, count: 0 });
    }

    history.forEach(function (r) {
        if (r.duration > 0) {
            var rDate = new Date(r.startedAt);
            rDate.setHours(0, 0, 0, 0);
            var rTime = rDate.getTime();
            for (var j = 0; j < days.length; j++) {
                if (days[j].date === rTime) {
                    days[j].totalMs += r.duration;
                    days[j].count++;
                    break;
                }
            }
        }
    });

    var maxAvg = 0;
    days.forEach(function (d) {
        d.avg = d.count > 0 ? d.totalMs / d.count : 0;
        if (d.avg > maxAvg) maxAvg = d.avg;
    });
    if (maxAvg < 1) maxAvg = 1;

    var html = '';
    days.forEach(function (d) {
        var h = d.avg > 0 ? Math.max((d.avg / maxAvg) * 140, 8) : 4;
        html += '<div class="bar-col">';
        if (d.avg > 0) html += '<div class="bar-value">' + formatDuration(d.avg) + '</div>';
        html += '<div class="bar-fill" style="height:' + h + 'px;background:' + (d.avg > 0 ? 'var(--accent)' : 'var(--border)') + '"></div>';
        html += '<div class="bar-label">' + d.label + '</div>';
        html += '</div>';
    });

    container.innerHTML = html;
}

/* ── History table ─────────────────────────────────────────────── */
var currentFilter = 'all';

function renderHistory() {
    var history = getHistory();
    var body = document.getElementById('historyBody');

    var filtered = history;
    if (currentFilter !== 'all') {
        filtered = history.filter(function (r) { return r.status === currentFilter; });
    }

    // Sort newest first
    filtered.sort(function (a, b) { return (b.startedAt || 0) - (a.startedAt || 0); });

    if (filtered.length === 0) {
        body.innerHTML = '<tr><td colspan="7" style="text-align:center;padding:40px;color:var(--text-muted)">No deployment records found. <button type="button" class="diag-link">&#128295; Troubleshoot connection</button></td></tr>';
        return;
    }

    var html = '';
    filtered.forEach(function (r) {
        var statusBadge = r.status === 'success'
            ? '<span class="history-status-badge success">&#10003; Success</span>'
            : '<span class="history-status-badge failed">&#10007; Failed</span>';

        var errorDisplay = r.failedStep && r.error
            ? r.failedStep + ': ' + r.error
            : (r.error || '—');

        html += '<tr>' +
            '<td>' + escapeHtml(r.deviceName || '—') + '</td>' +
            '<td>' + escapeHtml(r.taskSequence || '—') + '</td>' +
            '<td>' + statusBadge + '</td>' +
            '<td>' + formatDuration(r.duration) + '</td>' +
            '<td>' + (r.stepsCompleted || 0) + '/' + (r.stepsTotal || 0) + '</td>' +
            '<td>' + formatDate(r.startedAt) + '</td>' +
            '<td style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + escapeHtml(errorDisplay) + '">' + escapeHtml(errorDisplay) + '</td>' +
            '</tr>';
    });

    body.innerHTML = html;
}

/* History filter buttons */
document.querySelectorAll('.history-filter-btn').forEach(function (btn) {
    btn.addEventListener('click', function () {
        document.querySelectorAll('.history-filter-btn').forEach(function (b) { b.classList.remove('active'); });
        btn.classList.add('active');
        currentFilter = btn.getAttribute('data-filter');
        renderHistory();
    });
});

/* Export history as CSV */
function exportHistory() {
    var history = getHistory();
    if (history.length === 0) { alert('No deployment history to export.'); return; }

    var csvRows = ['Device,Task Sequence,Status,Duration (s),Steps Completed,Steps Total,Started,Completed,Failed Step,Error'];
    history.forEach(function (r) {
        var row = [
            '"' + (r.deviceName || '').replace(/"/g, '""') + '"',
            '"' + (r.taskSequence || '').replace(/"/g, '""') + '"',
            r.status || '',
            r.duration ? Math.round(r.duration / 1000) : 0,
            r.stepsCompleted || 0,
            r.stepsTotal || 0,
            r.startedAt ? new Date(r.startedAt).toISOString() : '',
            r.completedAt ? new Date(r.completedAt).toISOString() : '',
            '"' + (r.failedStep || '').replace(/"/g, '""') + '"',
            '"' + (r.error || '').replace(/"/g, '""') + '"'
        ];
        csvRows.push(row.join(','));
    });

    var blob = new Blob([csvRows.join('\n')], { type: 'text/csv' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'nova-deployments-' + new Date().toISOString().slice(0, 10) + '.csv';
    a.click();
    URL.revokeObjectURL(a.href);
}

/* ── Alert configuration ───────────────────────────────────────── */
function loadAlertConfig() {
    var cfg = getAlertConfig();

    document.getElementById('teamsEnabled').checked = cfg.teams.enabled;
    document.getElementById('teamsWebhook').value   = cfg.teams.webhook || '';
    document.getElementById('slackEnabled').checked  = cfg.slack.enabled;
    document.getElementById('slackWebhook').value    = cfg.slack.webhook || '';
    document.getElementById('emailEnabled').checked  = cfg.email.enabled;
    document.getElementById('emailSmtp').value       = cfg.email.smtp || '';
    document.getElementById('emailPort').value       = cfg.email.port || 587;
    document.getElementById('emailFrom').value       = cfg.email.from || '';
    document.getElementById('emailTo').value         = cfg.email.to || '';

    // Restore event checkboxes
    document.querySelectorAll('[data-channel][data-event]').forEach(function (cb) {
        var ch = cb.getAttribute('data-channel');
        var ev = cb.getAttribute('data-event');
        if (cfg[ch]) {
            cb.checked = ev === 'success' ? cfg[ch].onSuccess !== false : cfg[ch].onFailure !== false;
        }
    });

    updateConfigSnippet();
}

function saveAlertConfig() {
    var cfg = {
        teams: {
            enabled: document.getElementById('teamsEnabled').checked,
            webhook: document.getElementById('teamsWebhook').value.trim(),
            onSuccess: true,
            onFailure: true
        },
        slack: {
            enabled: document.getElementById('slackEnabled').checked,
            webhook: document.getElementById('slackWebhook').value.trim(),
            onSuccess: true,
            onFailure: true
        },
        email: {
            enabled: document.getElementById('emailEnabled').checked,
            smtp: document.getElementById('emailSmtp').value.trim(),
            port: parseInt(document.getElementById('emailPort').value, 10) || 587,
            from: document.getElementById('emailFrom').value.trim(),
            to: document.getElementById('emailTo').value.trim(),
            onSuccess: true,
            onFailure: true
        }
    };

    // Read event checkboxes
    document.querySelectorAll('[data-channel][data-event]').forEach(function (cb) {
        var ch = cb.getAttribute('data-channel');
        var ev = cb.getAttribute('data-event');
        if (cfg[ch]) {
            if (ev === 'success') cfg[ch].onSuccess = cb.checked;
            else cfg[ch].onFailure = cb.checked;
        }
    });

    localStorage.setItem(ALERTS_KEY, JSON.stringify(cfg));
    updateConfigSnippet();
}

function updateConfigSnippet() {
    var cfg = getAlertConfig();
    var json = JSON.stringify(cfg, null, 4);

    var snippet = '# Save this as config/alerts.json in your Nova repository.\n' +
        '# The Nova engine reads this file to send deployment notifications.\n' +
        json;

    document.getElementById('configSnippet').textContent = snippet;
}

function testAlert(channel) {
    var cfg = getAlertConfig();
    var c = cfg[channel];
    if (!c) { alert('Unknown channel: ' + channel); return; }

    if (channel === 'teams' || channel === 'slack') {
        if (!c.webhook) {
            alert('Please enter a webhook URL first.');
            return;
        }
        alert('Test notification would be sent to ' + channel.charAt(0).toUpperCase() + channel.slice(1) + '.\n\nIn production, the Nova deployment engine sends the notification via the webhook URL:\n' + c.webhook);
    } else if (channel === 'email') {
        if (!c.smtp || !c.from || !c.to) {
            alert('Please fill in SMTP server, From address, and To address first.');
            return;
        }
        alert('Test email notification would be sent via ' + c.smtp + ':' + c.port + '\nFrom: ' + c.from + '\nTo: ' + c.to);
    }
}

function copySnippet() {
    var text = document.getElementById('configSnippet').textContent;
    if (navigator.clipboard) {
        navigator.clipboard.writeText(text);
    } else {
        var ta = document.createElement('textarea');
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
    }
    var btn = document.querySelector('.config-snippet-copy');
    var orig = btn.innerHTML;
    btn.textContent = '\u2713 Copied';
    setTimeout(function () { btn.innerHTML = orig; }, 1500);
}

/* ── Sample data generator ─────────────────────────────────────── */
function addSampleData() {
    var devices = ['PC-DEPLOY-01', 'PC-DEPLOY-02', 'LAPTOP-HR-03', 'DESKTOP-IT-04', 'PC-SALES-05', 'LAPTOP-DEV-06', 'PC-EXEC-07', 'KIOSK-LOBBY-08'];
    var sequences = ['Default Nova Task Sequence', 'Windows 11 Enterprise', 'Windows 10 LTSC Kiosk', 'Autopilot Standard'];
    var errors = [
        'Network timeout during image download',
        'Disk partitioning failed: access denied',
        'Driver injection failed: no matching INF',
        'DISM apply failed: insufficient disk space',
        'Autopilot registration failed: invalid token',
        'WMI query timeout during condition check'
    ];
    var steps = ['PartitionDisk', 'DownloadImage', 'ApplyImage', 'SetBootloader', 'InjectDrivers', 'CustomizeOOBE'];

    var history = getHistory();
    var now = Date.now();

    // Generate records for last 7 days
    for (var day = 0; day < 7; day++) {
        var count = Math.floor(Math.random() * 5) + 1;
        for (var j = 0; j < count; j++) {
            var isSuccess = Math.random() > 0.25;
            var duration = isSuccess
                ? (Math.floor(Math.random() * 1200000) + 600000)   // 10-30 min
                : (Math.floor(Math.random() * 600000) + 60000);    // 1-10 min
            var totalSteps = Math.floor(Math.random() * 5) + 8;
            var completedSteps = isSuccess ? totalSteps : Math.floor(Math.random() * totalSteps);
            var startTime = now - (day * 86400000) - Math.floor(Math.random() * 86400000);

            history.push({
                id: 'dep_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7),
                deviceName: devices[Math.floor(Math.random() * devices.length)],
                taskSequence: sequences[Math.floor(Math.random() * sequences.length)],
                status: isSuccess ? 'success' : 'failed',
                duration: duration,
                stepsTotal: totalSteps,
                stepsCompleted: completedSteps,
                startedAt: startTime,
                completedAt: startTime + duration,
                error: isSuccess ? '' : errors[Math.floor(Math.random() * errors.length)],
                failedStep: isSuccess ? '' : steps[Math.floor(Math.random() * steps.length)]
            });
        }
    }

    saveHistory(history);

    // Add a couple of active deployments
    var activeList = [
        {
            id: 'active_1',
            deviceName: 'PC-DEPLOY-NEW',
            taskSequence: 'Default Nova Task Sequence',
            status: 'running',
            progress: 42,
            currentStep: 'Downloading Windows 11 23H2 image...',
            startedAt: now - 720000
        },
        {
            id: 'active_2',
            deviceName: 'LAPTOP-STAGING-02',
            taskSequence: 'Windows 11 Enterprise',
            status: 'running',
            progress: 78,
            currentStep: 'Injecting OEM drivers (Dell)...',
            startedAt: now - 1440000
        }
    ];
    saveActiveDeployments(activeList);

    renderAll();
}

function clearHistory() {
    if (!confirm('Clear all deployment history and active deployments?')) return;
    localStorage.removeItem(STORAGE_KEY);
    localStorage.removeItem(ACTIVE_KEY);
    renderAll();
}

/* ── Connection Diagnostics ────────────────────────────────────── */
var diagChecks = [
    { id: 'ghApi',     label: 'GitHub API Reachability' },
    { id: 'ghRepo',    label: 'Repository Access' },
    { id: 'ghAuth',    label: 'Authentication Status' },
    { id: 'ghRate',    label: 'API Rate Limit' },
    { id: 'authCfg',   label: 'Auth Configuration (config/auth.json)' },
    { id: 'reportsDir', label: 'Deployment Reports Directory' },
    { id: 'activeDir', label: 'Active Deployments Directory' }
];

function openDiagnostics() {
    document.getElementById('diagOverlay').classList.add('active');
    runDiagnostics();
}

function closeDiagnostics() {
    document.getElementById('diagOverlay').classList.remove('active');
}

function setCheckState(id, state, detail) {
    var el = document.getElementById('diag-' + id);
    if (!el) return;
    var iconEl = el.querySelector('.diag-check-icon');
    var detailEl = el.querySelector('.diag-check-detail');
    iconEl.className = 'diag-check-icon ' + state;
    iconEl.textContent = ({ pass: '\u2713', fail: '\u2717', warn: '!' })[state] || '';
    detailEl.textContent = detail;
}

function runDiagnostics() {
    var container = document.getElementById('diagChecks');
    var html = '';
    diagChecks.forEach(function (c) {
        html += '<div class="diag-check" id="diag-' + c.id + '">' +
            '<div class="diag-check-icon pending"></div>' +
            '<div class="diag-check-body">' +
                '<div class="diag-check-label">' + escapeHtml(c.label) + '</div>' +
                '<div class="diag-check-detail">Checking\u2026</div>' +
            '</div>' +
        '</div>';
    });
    container.innerHTML = html;
    document.getElementById('diagStatus').textContent = 'Running checks\u2026';

    var results = { passed: 0, warned: 0, failed: 0 };
    var rateLimitInfo = {};

    function finish(id, state, detail) {
        setCheckState(id, state, detail);
        if (state === 'pass') results.passed++;
        else if (state === 'warn') results.warned++;
        else results.failed++;
        var total = results.passed + results.warned + results.failed;
        if (total === diagChecks.length) {
            var statusEl = document.getElementById('diagStatus');
            if (results.failed > 0) {
                statusEl.textContent = results.failed + ' check(s) failed \u2014 see details above for resolution steps.';
            } else if (results.warned > 0) {
                statusEl.textContent = 'All checks passed with ' + results.warned + ' warning(s).';
            } else {
                statusEl.textContent = 'All checks passed. Data pipeline is healthy.';
            }
        }
    }

    /* 1. GitHub API reachability */
    fetch(GH_API + '/rate_limit', { headers: getGitHubHeaders() })
        .then(function (r) {
            if (r.ok) {
                return r.json().then(function (data) {
                    rateLimitInfo = data;
                    finish('ghApi', 'pass', 'GitHub API is reachable (HTTP ' + r.status + ').');
                });
            } else {
                finish('ghApi', 'fail', 'GitHub API returned HTTP ' + r.status + '. Check your network or firewall settings.');
            }
        })
        .catch(function (err) {
            finish('ghApi', 'fail', 'Cannot reach GitHub API. Check network connectivity or CORS/firewall settings. Error: ' + (err.message || err));
        });

    /* 2. Repository access */
    fetch(GH_API + '/repos/' + GH_OWNER + '/' + GH_REPO, { headers: getGitHubHeaders() })
        .then(function (r) {
            if (r.ok) {
                return r.json().then(function (data) {
                    finish('ghRepo', 'pass', 'Repository ' + GH_OWNER + '/' + GH_REPO + ' is accessible' + (data.private ? ' (private)' : ' (public)') + '.');
                });
            } else if (r.status === 404) {
                finish('ghRepo', 'fail', 'Repository ' + GH_OWNER + '/' + GH_REPO + ' not found. Verify GH_OWNER and GH_REPO are correct, or that the repo is not private without a valid token.');
            } else if (r.status === 403) {
                finish('ghRepo', 'fail', 'Access denied to ' + GH_OWNER + '/' + GH_REPO + '. The repository may be private and requires authentication.');
            } else {
                finish('ghRepo', 'fail', 'Repository check returned HTTP ' + r.status + '.');
            }
        })
        .catch(function (err) {
            finish('ghRepo', 'fail', 'Failed to check repository. Error: ' + (err.message || err));
        });

    /* 3. Authentication status */
    (function checkAuth() {
        if (cachedGhToken && Date.now() < ghTokenExpiry) {
            var remainingMs = ghTokenExpiry - Date.now();
            var remaining = Math.ceil(remainingMs / 60000);
            finish('ghAuth', 'pass', 'Authenticated with GitHub token (expires in ~' + remaining + ' min). Rate limit: 5,000 req/hr.');
        } else if (cachedGhToken && Date.now() >= ghTokenExpiry) {
            finish('ghAuth', 'warn', 'GitHub token has expired. The dashboard will use unauthenticated access (60 req/hr). Re-authenticate via Entra ID to restore higher limits.');
        } else {
            finish('ghAuth', 'warn', 'No GitHub token available. Using unauthenticated access (60 req/hr). For higher rate limits, configure Entra ID authentication in config/auth.json or set a GITHUB_TOKEN environment variable in the engine.');
        }
    })();

    /* 4. API rate limit */
    fetch(GH_API + '/rate_limit', { headers: getGitHubHeaders() })
        .then(function (r) {
            if (!r.ok) {
                finish('ghRate', 'warn', 'Could not fetch rate limit info (HTTP ' + r.status + ').');
                return;
            }
            return r.json().then(function (data) {
                var core = data && data.resources && data.resources.core;
                if (!core) {
                    finish('ghRate', 'warn', 'Rate limit data not available.');
                    return;
                }
                var remaining = core.remaining;
                var limit = core.limit;
                var resetAt = new Date(core.reset * 1000);
                var resetStr = resetAt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
                if (remaining === 0) {
                    finish('ghRate', 'fail', 'Rate limit exhausted (0/' + limit + '). Resets at ' + resetStr + '. Authenticate to increase limit to 5,000 req/hr.');
                } else if (remaining < 10) {
                    finish('ghRate', 'warn', remaining + '/' + limit + ' requests remaining. Resets at ' + resetStr + '. Consider authenticating for higher limits.');
                } else {
                    finish('ghRate', 'pass', remaining + '/' + limit + ' requests remaining. Resets at ' + resetStr + '.');
                }
            });
        })
        .catch(function (err) {
            finish('ghRate', 'warn', 'Could not check rate limit. Error: ' + (err.message || err));
        });

    /* 5. Auth config (config/auth.json) */
    var authUrl = 'https://raw.githubusercontent.com/' + GH_OWNER + '/' + GH_REPO + '/' + GH_BRANCH + '/config/auth.json';
    fetch(authUrl)
        .then(function (r) {
            if (r.ok) {
                return r.json().then(function (cfg) {
                    if (cfg && cfg.githubOAuthProxy) {
                        finish('authCfg', 'pass', 'Auth config loaded. OAuth proxy: ' + cfg.githubOAuthProxy);
                    } else {
                        finish('authCfg', 'warn', 'Auth config loaded but githubOAuthProxy is not set. Entra ID token exchange will not work.');
                    }
                });
            } else if (r.status === 404) {
                finish('authCfg', 'warn', 'config/auth.json not found. Entra ID authentication is not configured. Dashboard will use unauthenticated GitHub access.');
            } else {
                finish('authCfg', 'fail', 'Failed to load config/auth.json (HTTP ' + r.status + ').');
            }
        })
        .catch(function (err) {
            finish('authCfg', 'fail', 'Error loading auth config. Error: ' + (err.message || err));
        });

    /* 6. Deployment reports directory */
    var reportsUrl = GH_API + '/repos/' + GH_OWNER + '/' + GH_REPO + '/contents/deployments/reports?ref=' + GH_BRANCH;
    fetch(reportsUrl, { headers: getGitHubHeaders() })
        .then(function (r) {
            if (r.ok) {
                return r.json().then(function (files) {
                    var jsonFiles = Array.isArray(files) ? files.filter(function (f) { return f.name && f.name.endsWith('.json'); }) : [];
                    if (jsonFiles.length > 0) {
                        finish('reportsDir', 'pass', 'Found ' + jsonFiles.length + ' deployment report(s) in deployments/reports/.');
                    } else {
                        finish('reportsDir', 'warn', 'deployments/reports/ exists but contains no JSON files. Deployment reports will appear here after the engine completes a deployment.');
                    }
                });
            } else if (r.status === 404) {
                finish('reportsDir', 'warn', 'deployments/reports/ directory not found. This is normal if no deployment has been completed yet. The Nova engine creates this directory automatically when it pushes the first report.');
            } else {
                finish('reportsDir', 'fail', 'Cannot access deployments/reports/ (HTTP ' + r.status + '). Check repository permissions.');
            }
        })
        .catch(function (err) {
            finish('reportsDir', 'fail', 'Error checking reports directory. Error: ' + (err.message || err));
        });

    /* 7. Active deployments directory */
    var activeUrl = GH_API + '/repos/' + GH_OWNER + '/' + GH_REPO + '/contents/deployments/active?ref=' + GH_BRANCH;
    fetch(activeUrl, { headers: getGitHubHeaders() })
        .then(function (r) {
            if (r.ok) {
                return r.json().then(function (files) {
                    var jsonFiles = Array.isArray(files) ? files.filter(function (f) { return f.name && f.name.endsWith('.json'); }) : [];
                    if (jsonFiles.length > 0) {
                        finish('activeDir', 'pass', 'Found ' + jsonFiles.length + ' active deployment(s) in deployments/active/.');
                    } else {
                        finish('activeDir', 'warn', 'deployments/active/ exists but contains no JSON files. Active deployments will appear here while devices are being imaged.');
                    }
                });
            } else if (r.status === 404) {
                finish('activeDir', 'warn', 'deployments/active/ directory not found. This is normal if no deployment is in progress. The Nova engine creates this directory when a device starts imaging.');
            } else {
                finish('activeDir', 'fail', 'Cannot access deployments/active/ (HTTP ' + r.status + '). Check repository permissions.');
            }
        })
        .catch(function (err) {
            finish('activeDir', 'fail', 'Error checking active deployments directory. Error: ' + (err.message || err));
        });
}

/* ── Render everything ─────────────────────────────────────────── */
function renderAll() {
    renderSummary();
    renderActiveDeployments();
    renderBarChart();
    renderDonutChart();
    renderErrors();
    renderAvgTimeChart();
    renderHistory();
}

/* ── Event bindings (replaces inline handlers) ────────────────── */
document.getElementById('btnDiagnostics').addEventListener('click', function () { openDiagnostics(); });
document.getElementById('btnSampleData').addEventListener('click', function () { addSampleData(); });
document.getElementById('btnClearHistory').addEventListener('click', function () { clearHistory(); });
document.getElementById('btnExportHistory').addEventListener('click', function () { exportHistory(); });
document.getElementById('btnCopySnippet').addEventListener('click', function () { copySnippet(); });
document.getElementById('btnDiagClose').addEventListener('click', function () { closeDiagnostics(); });
document.getElementById('btnRerunDiag').addEventListener('click', function () { runDiagnostics(); });

/* Diagnostics overlay — click outside panel to close */
document.getElementById('diagOverlay').addEventListener('click', function (e) {
    if (e.target === this) closeDiagnostics();
});

/* Alert config — event delegation for toggles and inputs */
document.getElementById('tab-alerts').addEventListener('change', function () { saveAlertConfig(); });
document.getElementById('tab-alerts').addEventListener('input', function () { saveAlertConfig(); });

/* Test alert buttons */
document.querySelectorAll('[data-test-channel]').forEach(function (btn) {
    btn.addEventListener('click', function () { testAlert(btn.getAttribute('data-test-channel')); });
});

/* Delegated handlers for dynamically-generated elements */
document.addEventListener('click', function (e) {
    var link = e.target.closest('.diag-link');
    if (link) { openDiagnostics(); return; }

    var dismiss = e.target.closest('.deploy-dismiss-btn');
    if (dismiss && dismiss.dataset.deviceId) {
        dismissStaleDeployment(dismiss.dataset.deviceId);
    }
});

/* ── Init ──────────────────────────────────────────────────────── */
loadAlertConfig();
renderAll();
loadAuthConfig().then(function () { refreshFromGitHub(); });
setInterval(refreshFromGitHub, REFRESH_INTERVAL);