/* ─────────────────────────────────────────────────────────────────────
   AmpCloud Task Sequence Editor — app.js
   SCCM-style web UI for building and editing JSON task sequences that
   the AmpCloud engine (AmpCloud.ps1) can read and execute.
   ────────────────────────────────────────────────────────────────────── */

'use strict';

/* ── Step type registry ───────────────────────────────────────────── */
const STEP_TYPES = [
    {
        type: 'PartitionDisk',
        label: 'Partition Disk',
        description: 'Create GPT (UEFI) or MBR (BIOS) layout on the target drive',
        defaults: { diskNumber: 0, osDriveLetter: 'C' },
        fields: [
            { key: 'diskNumber', label: 'Disk number', kind: 'number', hint: 'Physical disk index (usually 0)' },
            { key: 'osDriveLetter', label: 'OS drive letter', kind: 'text', hint: 'Drive letter assigned to the OS partition' }
        ]
    },
    {
        type: 'ImportAutopilot',
        label: 'Import Autopilot Device',
        description: 'Register this device in Windows Autopilot via Microsoft Graph API before imaging',
        defaults: { groupTag: '', userEmail: '' },
        fields: [
            { key: 'groupTag', label: 'Group Tag', kind: 'text', hint: 'Autopilot group tag (alphanumeric, hyphens, underscores; max 100 chars)' },
            { key: 'userEmail', label: 'User Email', kind: 'text', hint: 'Optional user principal name to assign to the device' }
        ]
    },
    {
        type: 'DownloadImage',
        label: 'Download Windows Image',
        description: 'Fetch the Windows ESD/WIM from Microsoft CDN or a custom URL',
        defaults: { imageUrl: '', edition: 'Professional', language: 'en-us', architecture: 'x64' },
        fields: [
            { key: 'imageUrl', label: 'Image URL', kind: 'text', hint: 'Direct URL to .wim/.esd — leave empty to use products.xml' },
            { key: 'edition', label: 'Edition', kind: 'text', hint: 'Edition name from products.xml (e.g. Professional, Core, Education, Enterprise)' },
            { key: 'language', label: 'Language', kind: 'text', hint: 'BCP-47 language tag (e.g. en-us, fr-fr)' },
            { key: 'architecture', label: 'Architecture', kind: 'select', options: ['x64', 'ARM64'] }
        ]
    },
    {
        type: 'ApplyImage',
        label: 'Apply Windows Image',
        description: 'Expand the Windows image onto the target partition',
        defaults: { edition: 'Professional' },
        fields: [
            { key: 'edition', label: 'Edition', kind: 'text', hint: 'Edition name from products.xml (e.g. Professional, Core, Education, Enterprise)' }
        ]
    },
    {
        type: 'SetBootloader',
        label: 'Configure Bootloader',
        description: 'Write BCD store and EFI/MBR boot entries',
        defaults: {},
        fields: []
    },
    {
        type: 'InjectDrivers',
        label: 'Inject Drivers',
        description: 'Add network and storage drivers from a local or network path',
        defaults: { driverPath: '' },
        fields: [
            { key: 'driverPath', label: 'Driver path', kind: 'text', hint: 'Folder containing .inf driver files (WinPE or UNC path)' }
        ]
    },
    {
        type: 'InjectOemDrivers',
        label: 'Inject OEM Drivers',
        description: 'Auto-detect manufacturer (Dell/HP/Lenovo) and fetch latest drivers',
        defaults: {},
        fields: []
    },
    {
        type: 'ApplyAutopilot',
        label: 'Apply Autopilot Configuration',
        description: 'Embed the Autopilot/Intune provisioning profile',
        defaults: { jsonUrl: '', jsonPath: '' },
        fields: [
            { key: 'jsonUrl', label: 'JSON URL', kind: 'text', hint: 'URL to AutopilotConfigurationFile.json' },
            { key: 'jsonPath', label: 'JSON path', kind: 'text', hint: 'Or local path inside WinPE (takes precedence)' }
        ]
    },
    {
        type: 'StageCCMSetup',
        label: 'Stage ConfigMgr Setup',
        description: 'Stage ccmsetup.exe for first-boot ConfigMgr enrollment',
        defaults: { ccmSetupUrl: '' },
        fields: [
            { key: 'ccmSetupUrl', label: 'CCMSetup URL', kind: 'text', hint: 'URL to ccmsetup.exe (e.g. http://sccm.corp.local/ccmsetup.exe)' }
        ]
    },
    {
        type: 'SetComputerName',
        label: 'Set Computer Name',
        description: 'Configure the Windows computer name with naming rules (prefix, suffix, serial number)',
        defaults: { computerName: '', prefix: '', suffix: '', maxLength: 15, useSerialNumber: false },
        fields: [
            { key: 'computerName', label: 'Computer name', kind: 'text', hint: 'Static computer name (e.g. PC-001). If set, prefix/suffix/serial rules are ignored. Shown in config menu for editing.' },
            { key: 'prefix', label: 'Prefix', kind: 'text', hint: 'Prefix prepended to the generated name (e.g. AMP-)' },
            { key: 'suffix', label: 'Suffix', kind: 'text', hint: 'Suffix appended to the generated name (e.g. -PC)' },
            { key: 'maxLength', label: 'Max length', kind: 'number', hint: 'Maximum computer name length (NetBIOS limit is 15)' },
            { key: 'useSerialNumber', label: 'Use serial number', kind: 'checkbox', hint: 'Use the device serial number as the base name (prefix + serial + suffix)' }
        ]
    },
    {
        type: 'SetRegionalSettings',
        label: 'Set Regional Settings',
        description: 'Configure region, keyboard layout, and display language for the Windows installation',
        defaults: { inputLocale: '', systemLocale: '', userLocale: '', uiLanguage: '' },
        fields: [
            { key: 'inputLocale', label: 'Keyboard layout', kind: 'text', hint: 'Keyboard input locale (e.g. en-US, fr-FR, 0409:00000409). Shown in config menu.' },
            { key: 'systemLocale', label: 'System locale', kind: 'text', hint: 'System/region locale (e.g. en-US, fr-FR). Shown in config menu.' },
            { key: 'userLocale', label: 'User locale', kind: 'text', hint: 'User/format locale (e.g. en-US, fr-FR). Applied to unattend.xml.' },
            { key: 'uiLanguage', label: 'UI Language', kind: 'text', hint: 'Windows display language (e.g. en-US, fr-FR). Applied to unattend.xml.' }
        ]
    },
    {
        type: 'CustomizeOOBE',
        label: 'Customize OOBE',
        description: 'Apply unattend.xml for out-of-box experience customization',
        defaults: { unattendSource: 'default', unattendContent: '', unattendUrl: '', unattendPath: '' },
        fields: [
            { key: 'unattendSource', label: 'Unattend source', kind: 'select', options: ['default', 'cloud'], hint: 'Use the built-in default editor or provide a cloud URL / local path' },
            { key: 'unattendContent', label: 'Unattend XML', kind: 'xml', hint: 'Edit the default unattend.xml content applied during OOBE', showWhen: { key: 'unattendSource', value: 'default' } },
            { key: 'unattendUrl', label: 'Unattend URL', kind: 'text', hint: 'URL to unattend.xml', showWhen: { key: 'unattendSource', value: 'cloud' } },
            { key: 'unattendPath', label: 'Unattend path', kind: 'text', hint: 'Or local path inside WinPE (takes precedence)', showWhen: { key: 'unattendSource', value: 'cloud' } }
        ]
    },
    {
        type: 'RunPostScripts',
        label: 'Run Post-Provisioning Scripts',
        description: 'Download and stage PowerShell scripts for first-boot execution',
        defaults: { scriptUrls: [] },
        fields: [
            { key: 'scriptUrls', label: 'Script URLs', kind: 'array', hint: 'One URL per line — each .ps1 is staged in Windows\\Setup\\Scripts' }
        ]
    }
];

const typeMap = Object.fromEntries(STEP_TYPES.map(t => [t.type, t]));

/* ── State ────────────────────────────────────────────────────────── */
let taskSequence = {
    name: 'Default AmpCloud Task Sequence',
    version: '1.0',
    description: 'Standard cloud-native Windows deployment via AmpCloud',
    steps: []
};
let selectedIndex = -1;
let dragSrcIndex = -1;
let githubConfig = { owner: '', repo: '', clientId: '', oauthProxy: '' };

/* ── DOM refs ─────────────────────────────────────────────────────── */
const $stepList     = document.getElementById('stepList');
const $propsEmpty   = document.getElementById('propsEmpty');
const $propsEditor  = document.getElementById('propsEditor');
const $propName     = document.getElementById('propName');
const $propType     = document.getElementById('propType');
const $propDesc     = document.getElementById('propDescription');
const $propEnabled  = document.getElementById('propEnabled');
const $propContErr  = document.getElementById('propContinueOnError');
const $paramFields  = document.getElementById('paramFields');
const $tsName       = document.getElementById('tsName');
const $addDialog    = document.getElementById('addStepDialog');
const $addTypeList  = document.getElementById('stepTypeList');
const $addOk        = document.getElementById('btnAddStepOk');
const $fileInput    = document.getElementById('fileInput');

/* ── Populate type <select> ───────────────────────────────────────── */
STEP_TYPES.forEach(t => {
    const opt = document.createElement('option');
    opt.value = t.type;
    opt.textContent = t.label;
    $propType.appendChild(opt);
});

/* ── Render step list ─────────────────────────────────────────────── */
const STEP_BADGE_LABELS = {
    PartitionDisk: 'P', DownloadImage: 'D', ApplyImage: 'A', SetBootloader: 'B',
    InjectDrivers: 'I', InjectOemDrivers: 'O', ApplyAutopilot: 'AP',
    StageCCMSetup: 'S', CustomizeOOBE: 'C', RunPostScripts: 'R'
};

function renderStepList() {
    $stepList.innerHTML = '';
    taskSequence.steps.forEach((step, i) => {
        const li = document.createElement('li');
        li.className = 'step-item' + (i === selectedIndex ? ' selected' : '') + (step.enabled === false ? ' disabled' : '');
        li.draggable = true;
        li.dataset.index = i;

        const badge = STEP_BADGE_LABELS[step.type] || '?';

        li.innerHTML =
            '<span class="step-drag-handle" title="Drag to reorder">&#8942;&#8942;</span>' +
            '<span class="step-number">' + (i + 1) + '</span>' +
            '<span class="step-badge" data-type="' + escapeHtml(step.type) + '">' + badge + '</span>' +
            '<div class="step-info">' +
                '<div class="step-title">' + escapeHtml(step.name) + '</div>' +
                '<div class="step-type-label">' + escapeHtml(typeMap[step.type] ? typeMap[step.type].label : step.type) + '</div>' +
            '</div>';

        li.addEventListener('click', () => selectStep(i));

        /* Drag events */
        li.addEventListener('dragstart', onDragStart);
        li.addEventListener('dragover', onDragOver);
        li.addEventListener('dragleave', onDragLeave);
        li.addEventListener('drop', onDrop);
        li.addEventListener('dragend', onDragEnd);

        $stepList.appendChild(li);
    });
}

/* ── Select step ──────────────────────────────────────────────────── */
function selectStep(index) {
    selectedIndex = index;
    renderStepList();
    if (index < 0 || index >= taskSequence.steps.length) {
        $propsEmpty.style.display = '';
        $propsEditor.style.display = 'none';
        return;
    }
    $propsEmpty.style.display = 'none';
    $propsEditor.style.display = '';
    const step = taskSequence.steps[index];
    $propName.value = step.name || '';
    $propType.value = step.type || '';
    $propDesc.value = step.description || '';
    $propEnabled.checked = step.enabled !== false;
    $propContErr.checked = step.continueOnError === true;
    renderParamFields(step);
}

/* ── Render parameter fields dynamically ──────────────────────────── */
function renderParamFields(step) {
    $paramFields.innerHTML = '';
    const typeDef = typeMap[step.type];
    if (!typeDef || !typeDef.fields.length) {
        $paramFields.innerHTML = '<p style="color:var(--text-muted);font-size:12px;">This step has no configurable parameters.</p>';
        return;
    }
    if (!step.parameters) step.parameters = {};

    /* Collect all field wrappers so we can toggle visibility */
    const fieldWrappers = [];

    typeDef.fields.forEach(f => {
        const val = step.parameters[f.key] !== undefined ? step.parameters[f.key] : (typeDef.defaults[f.key] !== undefined ? typeDef.defaults[f.key] : '');
        const div = document.createElement('div');
        div.className = 'param-field' + (f.kind === 'array' ? ' param-field-array' : '') + (f.kind === 'xml' ? ' param-field-xml' : '');

        let inputHtml = '';
        if (f.kind === 'select') {
            const opts = (f.options || []).map(o => '<option value="' + escapeHtml(o) + '"' + (o === val ? ' selected' : '') + '>' + escapeHtml(o) + '</option>').join('');
            inputHtml = '<select data-param="' + f.key + '">' + opts + '</select>';
        } else if (f.kind === 'number') {
            inputHtml = '<input type="number" data-param="' + f.key + '" value="' + (typeof val === 'number' ? val : 0) + '">';
        } else if (f.kind === 'array') {
            const txt = Array.isArray(val) ? val.join('\n') : '';
            inputHtml = '<textarea data-param="' + f.key + '" data-kind="array" rows="3" placeholder="One entry per line">' + escapeHtml(txt) + '</textarea>';
        } else if (f.kind === 'xml') {
            inputHtml = '<div class="xml-editor-toolbar">' +
                '<button type="button" class="xml-tb-btn" data-action="format" title="Format / indent XML">&#9998; Format</button>' +
                '<button type="button" class="xml-tb-btn" data-action="validate" title="Check XML syntax">&#10003; Validate</button>' +
                '<button type="button" class="xml-tb-btn" data-action="reset" title="Reset to default unattend.xml">&#8634; Reset</button>' +
                '</div>' +
                '<div class="xml-editor-body">' +
                '<div class="xml-line-numbers" aria-hidden="true"></div>' +
                '<textarea data-param="' + f.key + '" data-kind="xml" rows="14" spellcheck="false" wrap="off">' + escapeHtml(String(val)) + '</textarea>' +
                '</div>' +
                '<div class="xml-validation"></div>';
        } else if (f.kind === 'checkbox') {
            inputHtml = '<input type="checkbox" data-param="' + f.key + '"' + (val ? ' checked' : '') + '>';
        } else {
            inputHtml = '<input type="text" data-param="' + f.key + '" value="' + escapeHtml(String(val)) + '">';
        }

        div.innerHTML = '<label>' + escapeHtml(f.label) + '</label>' + inputHtml +
            (f.hint ? '<div class="param-hint">' + escapeHtml(f.hint) + '</div>' : '');

        /* Live bind */
        const input = div.querySelector('[data-param]');
        const changeEvent = (f.kind === 'select' || f.kind === 'checkbox') ? 'change' : 'input';
        input.addEventListener(changeEvent, () => {
            if (!taskSequence.steps[selectedIndex]) return;
            if (!taskSequence.steps[selectedIndex].parameters) taskSequence.steps[selectedIndex].parameters = {};
            let v = input.value;
            if (f.kind === 'number') v = parseInt(v, 10) || 0;
            if (f.kind === 'array') v = input.value.split('\n').map(s => s.trim()).filter(Boolean);
            if (f.kind === 'checkbox') v = input.checked;
            taskSequence.steps[selectedIndex].parameters[f.key] = v;

            /* Re-evaluate showWhen visibility when a select changes */
            if (f.kind === 'select') applyShowWhen();

            /* Sync step values into unattend.xml when steps that touch it change */
            const stepType = taskSequence.steps[selectedIndex].type;
            if (stepType === 'SetComputerName' || stepType === 'SetRegionalSettings') {
                syncUnattendContent();
            }
        });

        /* Enhanced XML editor (toolbar, line numbers, tab-indent) */
        if (f.kind === 'xml') setupXmlEditor(div, input);

        fieldWrappers.push({ div: div, field: f });
        $paramFields.appendChild(div);
    });

    /* Apply conditional visibility based on showWhen rules */
    function applyShowWhen() {
        fieldWrappers.forEach(({ div, field }) => {
            if (!field.showWhen) return;
            const depVal = step.parameters[field.showWhen.key] !== undefined
                ? step.parameters[field.showWhen.key]
                : (typeDef.defaults[field.showWhen.key] || '');
            div.style.display = (depVal === field.showWhen.value) ? '' : 'none';
        });
    }
    applyShowWhen();
}

/* ── Property change handlers ─────────────────────────────────────── */
$propName.addEventListener('input', () => {
    if (selectedIndex < 0) return;
    taskSequence.steps[selectedIndex].name = $propName.value;
    renderStepList();
});
$propType.addEventListener('change', () => {
    if (selectedIndex < 0) return;
    const step = taskSequence.steps[selectedIndex];
    step.type = $propType.value;
    const def = typeMap[step.type];
    if (def) {
        step.parameters = structuredClone(def.defaults);
        if (!step.name || step.name === 'New Step') step.name = def.label;
        if (!step.description) step.description = def.description;
    }
    selectStep(selectedIndex);
    renderStepList();
});
$propDesc.addEventListener('input', () => {
    if (selectedIndex < 0) return;
    taskSequence.steps[selectedIndex].description = $propDesc.value;
});
$propEnabled.addEventListener('change', () => {
    if (selectedIndex < 0) return;
    taskSequence.steps[selectedIndex].enabled = $propEnabled.checked;
    renderStepList();
    /* Re-sync unattend.xml when a step that touches it is toggled */
    const t = taskSequence.steps[selectedIndex].type;
    if (t === 'SetComputerName' || t === 'SetRegionalSettings' || t === 'CustomizeOOBE') {
        syncUnattendContent();
    }
});
$propContErr.addEventListener('change', () => {
    if (selectedIndex < 0) return;
    taskSequence.steps[selectedIndex].continueOnError = $propContErr.checked;
});
$tsName.addEventListener('input', () => {
    taskSequence.name = $tsName.textContent.trim();
});

/* ── Drag-and-drop reorder ────────────────────────────────────────── */
function onDragStart(e) {
    dragSrcIndex = parseInt(e.currentTarget.dataset.index, 10);
    e.dataTransfer.effectAllowed = 'move';
    e.currentTarget.style.opacity = '0.4';
}
function onDragOver(e) {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    e.currentTarget.classList.add('drag-over');
}
function onDragLeave(e) {
    e.currentTarget.classList.remove('drag-over');
}
function onDrop(e) {
    e.preventDefault();
    e.currentTarget.classList.remove('drag-over');
    const destIndex = parseInt(e.currentTarget.dataset.index, 10);
    if (dragSrcIndex === destIndex) return;
    const moved = taskSequence.steps.splice(dragSrcIndex, 1)[0];
    taskSequence.steps.splice(destIndex, 0, moved);
    selectedIndex = destIndex;
    renderStepList();
    selectStep(selectedIndex);
}
function onDragEnd(e) {
    e.currentTarget.style.opacity = '';
    document.querySelectorAll('.step-item').forEach(el => el.classList.remove('drag-over'));
}

/* ── Move up / down ───────────────────────────────────────────────── */
document.getElementById('btnMoveUp').addEventListener('click', () => {
    if (selectedIndex <= 0) return;
    const tmp = taskSequence.steps[selectedIndex - 1];
    taskSequence.steps[selectedIndex - 1] = taskSequence.steps[selectedIndex];
    taskSequence.steps[selectedIndex] = tmp;
    selectedIndex--;
    renderStepList();
    selectStep(selectedIndex);
});
document.getElementById('btnMoveDown').addEventListener('click', () => {
    if (selectedIndex < 0 || selectedIndex >= taskSequence.steps.length - 1) return;
    const tmp = taskSequence.steps[selectedIndex + 1];
    taskSequence.steps[selectedIndex + 1] = taskSequence.steps[selectedIndex];
    taskSequence.steps[selectedIndex] = tmp;
    selectedIndex++;
    renderStepList();
    selectStep(selectedIndex);
});

/* ── Remove step ──────────────────────────────────────────────────── */
document.getElementById('btnRemoveStep').addEventListener('click', () => {
    if (selectedIndex < 0) return;
    const removedType = taskSequence.steps[selectedIndex].type;
    taskSequence.steps.splice(selectedIndex, 1);
    if (selectedIndex >= taskSequence.steps.length) selectedIndex = taskSequence.steps.length - 1;
    renderStepList();
    selectStep(selectedIndex);
    if (removedType === 'SetComputerName' || removedType === 'SetRegionalSettings') {
        syncUnattendContent();
    }
});

/* ── Add step dialog ──────────────────────────────────────────────── */
let addDialogChoice = null;

document.getElementById('btnAddStep').addEventListener('click', () => {
    addDialogChoice = null;
    $addOk.disabled = true;
    $addTypeList.innerHTML = '';
    STEP_TYPES.forEach(t => {
        const li = document.createElement('li');
        li.innerHTML = '<div class="st-name">' + escapeHtml(t.label) + '</div>' +
                       '<div class="st-desc">' + escapeHtml(t.description) + '</div>';
        li.addEventListener('click', () => {
            $addTypeList.querySelectorAll('li').forEach(el => el.classList.remove('selected'));
            li.classList.add('selected');
            addDialogChoice = t.type;
            $addOk.disabled = false;
        });
        $addTypeList.appendChild(li);
    });
    $addDialog.style.display = '';
});
document.getElementById('btnAddStepCancel').addEventListener('click', () => { $addDialog.style.display = 'none'; });
$addOk.addEventListener('click', () => {
    if (!addDialogChoice) return;
    $addDialog.style.display = 'none';
    const def = typeMap[addDialogChoice];
    const newStep = {
        id: addDialogChoice.toLowerCase() + '-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7),
        name: def.label,
        type: addDialogChoice,
        enabled: true,
        description: def.description,
        continueOnError: false,
        parameters: structuredClone(def.defaults)
    };
    const insertAt = selectedIndex >= 0 ? selectedIndex + 1 : taskSequence.steps.length;
    taskSequence.steps.splice(insertAt, 0, newStep);
    selectedIndex = insertAt;
    renderStepList();
    selectStep(selectedIndex);
    if (addDialogChoice === 'SetComputerName' || addDialogChoice === 'SetRegionalSettings') {
        syncUnattendContent();
    }
});

/* ── New ──────────────────────────────────────────────────────────── */
document.getElementById('btnNew').addEventListener('click', () => {
    if (!confirm('Create a new empty task sequence? Unsaved changes will be lost.')) return;
    taskSequence = { name: 'New Task Sequence', version: '1.0', description: '', steps: [] };
    $tsName.textContent = taskSequence.name;
    selectedIndex = -1;
    renderStepList();
    selectStep(-1);
});

/* ── Open JSON ────────────────────────────────────────────────────── */
document.getElementById('btnOpen').addEventListener('click', () => { $fileInput.click(); });
$fileInput.addEventListener('change', (e) => {
    const file = e.target.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (ev) => {
        try {
            const data = JSON.parse(ev.target.result);
            if (!data.steps || !Array.isArray(data.steps)) throw new Error('Invalid task sequence: missing steps array');
            taskSequence = data;

            /* Fill empty unattendContent from the repo file */
            populateDefaultUnattendContent(taskSequence.steps);

            /* Sync step values (SetComputerName, SetRegionalSettings) into unattend.xml */
            syncUnattendContent();

            $tsName.textContent = taskSequence.name || 'Untitled';
            selectedIndex = taskSequence.steps.length > 0 ? 0 : -1;
            renderStepList();
            selectStep(selectedIndex);
        } catch (err) {
            alert('Failed to load task sequence:\n' + err.message);
        }
    };
    reader.readAsText(file);
    $fileInput.value = '';
});

/* ── Save to GitHub ────────────────────────────────────────────────── */

/**
 * Prompt the user for a GitHub Personal Access Token via a modal dialog.
 * Used only as a fallback when the OAuth proxy is not configured.
 * @param {string} [fallbackReason] — Optional reason shown when Device Flow
 *        failed and we fell back to the PAT prompt.
 */
function getGitHubTokenViaPAT(fallbackReason) {
    return new Promise(function (resolve) {
        var overlay = document.createElement('div');
        overlay.className = 'dialog-overlay';
        var dialog = document.createElement('div');
        dialog.className = 'dialog';
        var warningHtml = fallbackReason
            ? '<p class="device-code-error" style="margin-bottom:12px;">\u26A0\uFE0F ' + escapeHtml(fallbackReason) + '</p>'
            : '';
        dialog.innerHTML =
            '<h2>GitHub Authentication</h2>' +
            warningHtml +
            '<p>Enter a GitHub Personal Access Token with <strong>repo contents write</strong> permission to save changes to the repository.</p>' +
            '<form id="ghTokenForm" autocomplete="off">' +
            '<div class="prop-group"><label for="ghTokenInput">Personal Access Token</label>' +
            '<input id="ghTokenInput" type="password" placeholder="ghp_\u2026" autocomplete="off"></div>' +
            '<div class="dialog-actions">' +
            '<button type="button" class="btn" id="ghTokenCancel">Cancel</button>' +
            '<button type="submit" class="btn btn-primary" id="ghTokenOk">Authenticate</button></div>' +
            '</form>';
        overlay.appendChild(dialog);
        document.body.appendChild(overlay);

        var input = document.getElementById('ghTokenInput');
        var form = document.getElementById('ghTokenForm');
        var btnCancel = document.getElementById('ghTokenCancel');
        input.focus();

        function cleanup(value) {
            document.body.removeChild(overlay);
            resolve(value);
        }
        form.addEventListener('submit', function (e) {
            e.preventDefault();
            var v = input.value.trim();
            if (v) {
                sessionStorage.setItem('ampcloud_github_token', v);
                cleanup(v);
            }
        });
        btnCancel.addEventListener('click', function () { cleanup(null); });
        input.addEventListener('keydown', function (e) {
            if (e.key === 'Escape') btnCancel.click();
        });
    });
}

/**
 * Show a Device Flow dialog: displays the user code, a link to GitHub,
 * and polls for the access token in the background via the CORS proxy.
 */
function showDeviceCodeDialog(deviceData, resolve) {
    var overlay = document.createElement('div');
    overlay.className = 'dialog-overlay';
    var dialog = document.createElement('div');
    dialog.className = 'dialog';
    var safeCode = escapeHtml(deviceData.user_code);
    var uri = deviceData.verification_uri;
    /* Only allow https URLs for the verification link. */
    if (!/^https:\/\//i.test(uri)) uri = 'https://github.com/login/device';
    var safeUri = escapeHtml(uri);
    dialog.innerHTML =
        '<h2>Sign in with GitHub</h2>' +
        '<p>Copy the code below, then click <strong>Open GitHub</strong> to authorize.</p>' +
        '<div class="device-code-box">' +
            '<code class="device-code-value">' + safeCode + '</code>' +
            '<button class="btn device-code-copy" id="ghCopyCode" title="Copy code">\uD83D\uDCCB Copy</button>' +
        '</div>' +
        '<div class="dialog-actions" style="justify-content:center;margin-top:14px;">' +
            '<a href="' + safeUri + '" target="_blank" rel="noopener" class="btn btn-primary" id="ghOpenLink">' +
            '\uD83D\uDD17 Open GitHub</a>' +
        '</div>' +
        '<p id="ghDeviceStatus" class="device-code-status">' +
            '<span class="login-spinner" aria-hidden="true"></span> Waiting for authorization\u2026</p>' +
        '<div class="dialog-actions">' +
            '<button class="btn" id="ghDeviceCancel">Cancel</button>' +
        '</div>';
    overlay.appendChild(dialog);
    document.body.appendChild(overlay);

    var polling = true;
    var interval = (deviceData.interval || 5) * 1000;
    var networkErrors = 0;
    var maxNetworkErrors = 12;

    function cleanup(token) {
        polling = false;
        document.body.removeChild(overlay);
        resolve(token);
    }

    function showStatusError(msg) {
        var el = document.getElementById('ghDeviceStatus');
        el.textContent = msg;
        el.className = 'device-code-status device-code-error';
    }

    document.getElementById('ghCopyCode').addEventListener('click', function () {
        var btn = this;
        navigator.clipboard.writeText(deviceData.user_code).then(function () {
            btn.textContent = '\u2705 Copied';
            setTimeout(function () { btn.textContent = '\uD83D\uDCCB Copy'; }, 2000);
        });
    });

    document.getElementById('ghDeviceCancel').addEventListener('click', function () {
        cleanup(null);
    });

    /* Poll the token endpoint via the CORS proxy until the user completes authorization. */
    function poll() {
        if (!polling) return;
        fetch(githubConfig.oauthProxy + '/login/oauth/access_token', {
            method: 'POST',
            headers: { 'Accept': 'application/json', 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ client_id: githubConfig.clientId, device_code: deviceData.device_code, grant_type: 'urn:ietf:params:oauth:grant-type:device_code' })
        })
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (!polling) return;
            networkErrors = 0;
            if (data.access_token) {
                sessionStorage.setItem('ampcloud_github_token', data.access_token);
                cleanup(data.access_token);
            } else if (data.error === 'slow_down') {
                /* GitHub asks us to increase the polling interval. */
                interval += 5000;
                setTimeout(poll, interval);
            } else if (data.error === 'authorization_pending') {
                setTimeout(poll, interval);
            } else if (data.error === 'expired_token') {
                showStatusError('Code expired. Please close this dialog and try again.');
            } else {
                showStatusError(data.error_description || 'Authentication failed. Please try again.');
            }
        })
        .catch(function (err) {
            console.warn('[AmpCloud] Device Flow token poll error:', err);
            networkErrors++;
            if (polling && networkErrors < maxNetworkErrors) {
                setTimeout(poll, interval);
            } else if (polling) {
                showStatusError('Network error. Please check your connection and try again.');
            }
        });
    }

    setTimeout(poll, interval);
}

/**
 * Obtain a GitHub token for saving.
 * Uses OAuth Device Flow via a CORS proxy when configured (proper consent).
 * Falls back to a Personal Access Token prompt otherwise.
 */
function getGitHubToken() {
    return new Promise(function (resolve) {
        var existing = sessionStorage.getItem('ampcloud_github_token');
        if (existing) { resolve(existing); return; }

        /* If both a GitHub OAuth App client ID and CORS proxy are configured,
           use Device Flow so the user sees a proper GitHub consent screen. */
        if (githubConfig.clientId && githubConfig.oauthProxy) {
            fetch(githubConfig.oauthProxy + '/login/device/code', {
                method: 'POST',
                headers: { 'Accept': 'application/json', 'Content-Type': 'application/x-www-form-urlencoded' },
                body: new URLSearchParams({ client_id: githubConfig.clientId, scope: 'repo' })
            })
            .then(function (r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.json();
            })
            .then(function (data) {
                if (data.error) {
                    throw new Error(data.error + (data.error_description ? ' \u2014 ' + data.error_description : ''));
                }
                if (!data.device_code || !data.user_code) throw new Error('Invalid device code response');
                showDeviceCodeDialog(data, resolve);
            })
            .catch(function (err) {
                console.warn('[AmpCloud] GitHub Device Flow failed, falling back to PAT.', err);
                var reason = err && err.message === 'Failed to fetch'
                    ? 'Could not reach the OAuth proxy (CORS or network error). Using Personal Access Token instead.'
                    : 'GitHub Device Flow failed: ' + (err && err.message ? err.message : 'unknown error');
                getGitHubTokenViaPAT(reason).then(resolve);
            });
            return;
        }

        /* No OAuth proxy configured — prompt for a PAT. */
        getGitHubTokenViaPAT().then(resolve);
    });
}

function toBase64(str) {
    const bytes = new TextEncoder().encode(str);
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary);
}

document.getElementById('btnSave').addEventListener('click', async () => {
    if (!githubConfig.owner || !githubConfig.repo) {
        alert('GitHub repository is not configured. Save to repo is unavailable.');
        return;
    }

    const token = await getGitHubToken();
    if (!token) return;

    const btnSave = document.getElementById('btnSave');
    const origLabel = btnSave.innerHTML;
    btnSave.textContent = '\u23F3 Saving\u2026';
    btnSave.disabled = true;

    try {
        const json = JSON.stringify(taskSequence, null, 2) + '\n';
        const path = 'TaskSequence/default.json';
        const apiBase = 'https://api.github.com/repos/' + encodeURIComponent(githubConfig.owner) + '/' + encodeURIComponent(githubConfig.repo) + '/contents/' + path;
        const headers = { 'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github.v3+json' };

        /* Get current SHA */
        const getResp = await fetch(apiBase, { headers: headers });
        if (getResp.status === 401 || getResp.status === 403) {
            sessionStorage.removeItem('ampcloud_github_token');
            throw new Error('Invalid or expired GitHub token. Please try saving again.');
        }
        if (!getResp.ok) throw new Error('Failed to read file from GitHub (HTTP ' + getResp.status + ')');
        const fileData = await getResp.json();

        /* Update file */
        const putResp = await fetch(apiBase, {
            method: 'PUT',
            headers: Object.assign({ 'Content-Type': 'application/json' }, headers),
            body: JSON.stringify({
                message: 'Update default.json via AmpCloud Editor',
                content: toBase64(json),
                sha: fileData.sha
            })
        });
        if (putResp.status === 401 || putResp.status === 403) {
            sessionStorage.removeItem('ampcloud_github_token');
            throw new Error('GitHub token lacks write permission. Please try saving again with a valid token.');
        }
        if (!putResp.ok) {
            const errBody = await putResp.json().catch(function () { return {}; });
            throw new Error(errBody.message || 'GitHub API error (HTTP ' + putResp.status + ')');
        }

        btnSave.textContent = '\u2705 Saved';
        setTimeout(function () { btnSave.innerHTML = origLabel; }, 2000);
    } catch (err) {
        alert('Save failed:\n' + err.message);
        btnSave.innerHTML = origLabel;
    } finally {
        btnSave.disabled = false;
    }
});

/* ── Download JSON ────────────────────────────────────────────────── */
document.getElementById('btnDownload').addEventListener('click', () => {
    const json = JSON.stringify(taskSequence, null, 2);
    const blob = new Blob([json], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    const safeName = (taskSequence.name || 'tasksequence').replace(/[^a-zA-Z0-9_-]/g, '_').substring(0, 60);
    a.download = safeName + '.json';
    a.click();
    URL.revokeObjectURL(a.href);
});

/* ── Utils ────────────────────────────────────────────────────────── */
function escapeHtml(str) {
    const d = document.createElement('div');
    d.appendChild(document.createTextNode(str));
    return d.innerHTML;
}

/* ── XML helpers ──────────────────────────────────────────────────── */

/** Pretty-print XML with consistent 2-space indentation. */
function formatXml(xml) {
    try {
        let formatted = '';
        let indent = 0;
        const tokens = xml.replace(/>\s*</g, '>\n<').split('\n');
        tokens.forEach(line => {
            line = line.trim();
            if (!line) return;
            if (line.match(/^<\//)) indent = Math.max(0, indent - 1);
            formatted += '  '.repeat(indent) + line + '\n';
            if (line.match(/^<[^\/!?]/) && !line.match(/\/>$/) && !line.match(/<\/[^>]+>$/)) indent++;
        });
        return formatted.trimEnd();
    } catch (_) { return xml; }
}

/** Check well-formedness using DOMParser. Returns {valid, error}. */
function validateXml(xml) {
    if (!xml.trim()) return { valid: false, error: 'XML content is empty' };
    const doc = new DOMParser().parseFromString(xml, 'application/xml');
    const err = doc.querySelector('parsererror');
    if (err) {
        const msg = (err.textContent || 'Invalid XML').split('\n')[0];
        return { valid: false, error: msg };
    }
    return { valid: true, error: '' };
}

/** Wire up toolbar, line numbers, tab-indent, and validation for an XML field. */
function setupXmlEditor(container, textarea) {
    const lineNums = container.querySelector('.xml-line-numbers');
    const validBar = container.querySelector('.xml-validation');

    function updateLineNumbers() {
        const count = textarea.value.split('\n').length;
        let nums = '';
        for (let i = 1; i <= count; i++) nums += i + '\n';
        lineNums.textContent = nums;
    }

    textarea.addEventListener('input', updateLineNumbers);
    textarea.addEventListener('scroll', () => { lineNums.scrollTop = textarea.scrollTop; });
    updateLineNumbers();

    /* Tab → insert 2 spaces instead of moving focus */
    textarea.addEventListener('keydown', (e) => {
        if (e.key === 'Tab') {
            e.preventDefault();
            const start = textarea.selectionStart;
            const end = textarea.selectionEnd;
            textarea.value = textarea.value.substring(0, start) + '  ' + textarea.value.substring(end);
            textarea.selectionStart = textarea.selectionEnd = start + 2;
            textarea.dispatchEvent(new Event('input'));
        }
    });

    /* Toolbar actions */
    container.querySelectorAll('.xml-tb-btn').forEach((btn) => {
        btn.addEventListener('click', () => {
            const action = btn.getAttribute('data-action');
            if (action === 'format') {
                textarea.value = formatXml(textarea.value);
                textarea.dispatchEvent(new Event('input'));
            } else if (action === 'validate') {
                const r = validateXml(textarea.value);
                validBar.className = 'xml-validation ' + (r.valid ? 'xml-valid' : 'xml-invalid');
                validBar.textContent = r.valid ? '\u2713 XML is well-formed' : '\u2717 ' + r.error;
            } else if (action === 'reset') {
                /* defaultUnattendXml is populated by loadDefault() at startup */
                if (!defaultUnattendXml) {
                    validBar.className = 'xml-validation xml-invalid';
                    validBar.textContent = 'Default template not available';
                    return;
                }
                if (confirm('Reset to the default unattend.xml content?')) {
                    textarea.value = defaultUnattendXml;
                    textarea.dispatchEvent(new Event('input'));
                    validBar.className = 'xml-validation';
                    validBar.textContent = '';
                }
            }
        });
    });
}

/* ── Keyboard shortcuts ───────────────────────────────────────────── */
document.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT' || e.target.isContentEditable) return;
    if (e.key === 'Delete' && selectedIndex >= 0) {
        document.getElementById('btnRemoveStep').click();
    }
});

/* ── Sync step values into unattend.xml ───────────────────────────── */

/**
 * Whenever a step that touches unattend.xml (SetComputerName,
 * SetRegionalSettings) is added, removed, enabled/disabled, or has its
 * parameters edited, this function injects the current values into the
 * CustomizeOOBE step's unattendContent XML.
 *
 * ComputerName → specialize pass (Microsoft-Windows-Shell-Setup)
 * Locale settings → oobeSystem pass (Microsoft-Windows-International-Core)
 *
 * This keeps the task sequence as the single source of truth — the engine
 * just writes unattendContent to disk without any XML manipulation.
 */
function syncUnattendContent() {
    if (!taskSequence.steps || !taskSequence.steps.length) return;

    /* Find the CustomizeOOBE step with unattendSource === 'default' */
    var oobeStep = null;
    for (var i = 0; i < taskSequence.steps.length; i++) {
        var s = taskSequence.steps[i];
        if (s.type === 'CustomizeOOBE' && s.enabled !== false) {
            var src = s.parameters && s.parameters.unattendSource;
            if (!src || src === 'default') { oobeStep = s; break; }
        }
    }
    if (!oobeStep) return;
    if (!oobeStep.parameters) oobeStep.parameters = {};

    /* Collect values from enabled SetComputerName / SetRegionalSettings steps */
    var computerName = '';
    var inputLocale = '', systemLocale = '', userLocale = '', uiLanguage = '';

    taskSequence.steps.forEach(function (s) {
        if (s.enabled === false || !s.parameters) return;
        if (s.type === 'SetComputerName') {
            computerName = s.parameters.computerName || '';
        } else if (s.type === 'SetRegionalSettings') {
            inputLocale  = s.parameters.inputLocale  || '';
            systemLocale = s.parameters.systemLocale || '';
            userLocale   = s.parameters.userLocale   || '';
            uiLanguage   = s.parameters.uiLanguage   || '';
        }
    });

    /* Parse the existing unattendContent (or start from default) */
    var xml = oobeStep.parameters.unattendContent || defaultUnattendXml;
    if (!xml) return;

    var parser = new DOMParser();
    var doc = parser.parseFromString(xml, 'application/xml');
    if (doc.querySelector('parsererror')) return;   /* Don't touch invalid XML */

    var NS = 'urn:schemas-microsoft-com:unattend';

    /** Find or create an element within parent (unattend namespace). */
    function ensureElement(parent, localName, attrs) {
        var selector = localName;
        var child = null;
        /* Search children manually to handle namespaced elements */
        for (var c = parent.firstElementChild; c; c = c.nextElementSibling) {
            if (c.localName === localName) {
                var match = true;
                if (attrs) {
                    for (var k in attrs) {
                        if (c.getAttribute(k) !== attrs[k]) { match = false; break; }
                    }
                }
                if (match) { child = c; break; }
            }
        }
        if (!child) {
            child = doc.createElementNS(NS, localName);
            if (attrs) {
                for (var k in attrs) child.setAttribute(k, attrs[k]);
            }
            parent.appendChild(child);
        }
        return child;
    }

    /** Remove an element if it exists. */
    function removeElement(parent, localName) {
        for (var c = parent.firstElementChild; c; c = c.nextElementSibling) {
            if (c.localName === localName) { parent.removeChild(c); return; }
        }
    }

    /* ── ComputerName → specialize pass ─────────────────────────────── */
    var specPass = null;
    for (var c = doc.documentElement.firstElementChild; c; c = c.nextElementSibling) {
        if (c.localName === 'settings' && c.getAttribute('pass') === 'specialize') { specPass = c; break; }
    }

    if (computerName) {
        if (!specPass) {
            specPass = ensureElement(doc.documentElement, 'settings', { pass: 'specialize' });
        }
        var shellComp = ensureElement(specPass, 'component', { name: 'Microsoft-Windows-Shell-Setup' });
        if (!shellComp.getAttribute('processorArchitecture')) {
            shellComp.setAttribute('processorArchitecture', 'amd64');
            shellComp.setAttribute('publicKeyToken', '31bf3856ad364e35');
            shellComp.setAttribute('language', 'neutral');
            shellComp.setAttribute('versionScope', 'nonSxS');
        }
        var cnNode = ensureElement(shellComp, 'ComputerName');
        cnNode.textContent = computerName;
    } else if (specPass) {
        /* Remove ComputerName element if name was cleared */
        for (var c = specPass.firstElementChild; c; c = c.nextElementSibling) {
            if (c.localName === 'component' && c.getAttribute('name') === 'Microsoft-Windows-Shell-Setup') {
                removeElement(c, 'ComputerName');
                /* Remove the component if it's now empty */
                if (!c.firstElementChild) { specPass.removeChild(c); }
                break;
            }
        }
        /* Remove the specialize pass if it's now empty */
        if (!specPass.firstElementChild) { doc.documentElement.removeChild(specPass); }
    }

    /* ── Locale settings → oobeSystem pass ──────────────────────────── */
    var hasLocale = inputLocale || systemLocale || userLocale || uiLanguage;
    var oobePass = null;
    for (var c = doc.documentElement.firstElementChild; c; c = c.nextElementSibling) {
        if (c.localName === 'settings' && c.getAttribute('pass') === 'oobeSystem') { oobePass = c; break; }
    }

    if (hasLocale) {
        if (!oobePass) {
            oobePass = ensureElement(doc.documentElement, 'settings', { pass: 'oobeSystem' });
        }
        var intlComp = ensureElement(oobePass, 'component', { name: 'Microsoft-Windows-International-Core' });
        if (!intlComp.getAttribute('processorArchitecture')) {
            intlComp.setAttribute('processorArchitecture', 'amd64');
            intlComp.setAttribute('publicKeyToken', '31bf3856ad364e35');
            intlComp.setAttribute('language', 'neutral');
            intlComp.setAttribute('versionScope', 'nonSxS');
        }
        var locales = [
            ['InputLocale', inputLocale], ['SystemLocale', systemLocale],
            ['UserLocale', userLocale], ['UILanguage', uiLanguage]
        ];
        locales.forEach(function (pair) {
            var tag = pair[0], val = pair[1];
            if (val) {
                ensureElement(intlComp, tag).textContent = val;
            } else {
                removeElement(intlComp, tag);
            }
        });
        /* Remove International-Core component if all locale fields are empty */
        if (!intlComp.firstElementChild) { oobePass.removeChild(intlComp); }
    } else if (oobePass) {
        /* Remove International-Core component when all locale values are cleared */
        for (var c = oobePass.firstElementChild; c; c = c.nextElementSibling) {
            if (c.localName === 'component' && c.getAttribute('name') === 'Microsoft-Windows-International-Core') {
                oobePass.removeChild(c);
                break;
            }
        }
    }

    /* Serialize and update */
    var serializer = new XMLSerializer();
    var raw = serializer.serializeToString(doc);
    oobeStep.parameters.unattendContent = formatXml(raw);

    /* If the CustomizeOOBE step is currently selected, refresh its XML textarea */
    if (selectedIndex >= 0 && taskSequence.steps[selectedIndex] === oobeStep) {
        var ta = document.querySelector('[data-param="unattendContent"]');
        if (ta) {
            ta.value = oobeStep.parameters.unattendContent;
            ta.dispatchEvent(new Event('input'));  /* Update line numbers */
        }
    }
}

/* ── Default unattend.xml content (loaded from repo) ──────────────── */
let defaultUnattendXml = '';

/** Fill empty unattendContent from the repo-hosted file for all CustomizeOOBE steps */
function populateDefaultUnattendContent(steps) {
    if (!defaultUnattendXml) return;
    steps.forEach(step => {
        if (step.type === 'CustomizeOOBE' && step.parameters && !step.parameters.unattendContent) {
            step.parameters.unattendContent = defaultUnattendXml;
        }
    });
}

/* ── Load default task sequence on start ──────────────────────────── */
function loadDefault() {
    Promise.all([
        fetch('../TaskSequence/default.json')
            .then(r => { if (!r.ok) throw new Error(r.statusText); return r.json(); }),
        fetch('../Unattend/unattend.xml')
            .then(r => { if (!r.ok) throw new Error(r.statusText); return r.text(); })
            .catch(() => '')
    ]).then(([data, xml]) => {
        defaultUnattendXml = xml;

        /* Use the repo XML as the default for the CustomizeOOBE type */
        if (defaultUnattendXml) {
            typeMap.CustomizeOOBE.defaults.unattendContent = defaultUnattendXml;
        }

        taskSequence = data;

        /* Fill empty unattendContent from the repo file */
        populateDefaultUnattendContent(taskSequence.steps);

        /* Sync step values (SetComputerName, SetRegionalSettings) into unattend.xml */
        syncUnattendContent();

        $tsName.textContent = taskSequence.name || 'Untitled';
        selectedIndex = taskSequence.steps.length > 0 ? 0 : -1;
        renderStepList();
        selectStep(selectedIndex);
    }).catch(() => {
        /* No default file available — start empty */
        renderStepList();
    });
}

/* ── MSAL Authentication Gate ─────────────────────────────────────── */
(function initAuth() {
    const loginOverlay  = document.getElementById('loginOverlay');
    const btnLogin      = document.getElementById('btnLogin');
    const btnLogout     = document.getElementById('btnLogout');
    const loginError    = document.getElementById('loginError');
    const loginLoading  = document.getElementById('loginLoading');
    const userName      = document.getElementById('userName');
    const toolbar       = document.querySelector('.toolbar');
    const mainLayout    = document.querySelector('.main');

    /** Reveal the editor and hide the login overlay. */
    function showEditor(account) {
        loginOverlay.style.display = 'none';
        toolbar.style.display = '';
        mainLayout.style.display = '';
        if (account && account.name) {
            userName.textContent = account.name;
            userName.style.display = '';
            btnLogout.style.display = '';
        }
        loadDefault();
    }

    /** Show the login UI (hide loading text, show button). */
    function showLoginUI() {
        loginLoading.style.display = 'none';
        btnLogin.style.display = '';
    }

    /* Fetch auth config from the repository. */
    fetch('../Config/auth.json')
        .then(r => { if (!r.ok) throw new Error(r.statusText); return r.json(); })
        .then(config => {
            /* Store GitHub repo info for Save-to-repo feature */
            if (config.githubOwner && config.githubRepo) {
                githubConfig.owner = config.githubOwner;
                githubConfig.repo = config.githubRepo;
            }
            if (config.githubClientId) {
                githubConfig.clientId = config.githubClientId;
            }
            if (config.githubOAuthProxy && typeof config.githubOAuthProxy === 'string' && config.githubOAuthProxy.trim()) {
                githubConfig.oauthProxy = config.githubOAuthProxy.trim().replace(/\/+$/, '');
            }

            if (!config.requireAuth || !config.clientId) {
                /* Auth disabled — show editor immediately. */
                showEditor(null);
                return;
            }

            /* Ensure MSAL loaded from CDN. */
            if (typeof msal === 'undefined') {
                loginLoading.style.display = 'none';
                btnLogin.style.display = 'none';
                loginError.textContent = 'Authentication library failed to load. Check your network, ad-blocker, or corporate network restrictions.';
                loginError.style.display = '';
                return;
            }

            /* Initialise MSAL */
            const msalConfig = {
                auth: {
                    clientId: config.clientId,
                    authority: 'https://login.microsoftonline.com/organizations',
                    redirectUri: config.redirectUri || (window.location.origin + window.location.pathname)
                },
                cache: { cacheLocation: 'sessionStorage' }
            };
            const msalApp = new msal.PublicClientApplication(msalConfig);

            /* Handle redirect response (for redirect flow). */
            msalApp.handleRedirectPromise().then(response => {
                if (response && response.account) {
                    msalApp.setActiveAccount(response.account);
                    showEditor(response.account);
                    return;
                }
                /* Check if already signed in. */
                const accounts = msalApp.getAllAccounts();
                if (accounts.length > 0) {
                    msalApp.setActiveAccount(accounts[0]);
                    showEditor(accounts[0]);
                    return;
                }
                /* No session — show login UI. */
                showLoginUI();
            }).catch(() => {
                showLoginUI();
            });

            /* Sign-in button — only openid + profile are needed; this is a
               pure identity gate, not an API permission request.
               Use redirect (not popup) to avoid Cross-Origin-Opener-Policy
               errors from login.microsoftonline.com. */
            btnLogin.addEventListener('click', () => {
                loginError.style.display = 'none';
                msalApp.loginRedirect({ scopes: ['openid', 'profile'] });
            });

            /* Sign-out — redirect flow avoids COOP popup issues. */
            btnLogout.addEventListener('click', () => {
                msalApp.logoutRedirect();
            });
        })
        .catch(() => {
            /* Config not available — show editor without auth. */
            showEditor(null);
        });
})();
