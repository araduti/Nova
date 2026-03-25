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
        type: 'DownloadImage',
        label: 'Download Windows Image',
        description: 'Fetch the Windows ESD/WIM from Microsoft CDN or a custom URL',
        defaults: { imageUrl: '', edition: 'Professional', language: 'en-us', architecture: 'x64' },
        fields: [
            { key: 'imageUrl', label: 'Image URL', kind: 'text', hint: 'Direct URL to .wim/.esd — leave empty to use products.xml' },
            { key: 'edition', label: 'Edition', kind: 'select', options: ['Professional', 'Core', 'Education', 'Enterprise', 'ProfessionalWorkstation', 'ProfessionalEducation'] },
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
            { key: 'edition', label: 'Edition', kind: 'select', options: ['Professional', 'Core', 'Education', 'Enterprise', 'ProfessionalWorkstation', 'ProfessionalEducation'] }
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
        type: 'CustomizeOOBE',
        label: 'Customize OOBE',
        description: 'Apply unattend.xml for out-of-box experience customization',
        defaults: { unattendUrl: '', unattendPath: '' },
        fields: [
            { key: 'unattendUrl', label: 'Unattend URL', kind: 'text', hint: 'URL to unattend.xml' },
            { key: 'unattendPath', label: 'Unattend path', kind: 'text', hint: 'Or local path inside WinPE (takes precedence)' }
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
function renderStepList() {
    $stepList.innerHTML = '';
    taskSequence.steps.forEach((step, i) => {
        const li = document.createElement('li');
        li.className = 'step-item' + (i === selectedIndex ? ' selected' : '') + (step.enabled === false ? ' disabled' : '');
        li.draggable = true;
        li.dataset.index = i;

        li.innerHTML =
            '<span class="step-drag-handle" title="Drag to reorder">&#8942;&#8942;</span>' +
            '<span class="step-number">' + (i + 1) + '</span>' +
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
    typeDef.fields.forEach(f => {
        const val = step.parameters[f.key] !== undefined ? step.parameters[f.key] : (typeDef.defaults[f.key] !== undefined ? typeDef.defaults[f.key] : '');
        const div = document.createElement('div');
        div.className = 'param-field' + (f.kind === 'array' ? ' param-field-array' : '');

        let inputHtml = '';
        if (f.kind === 'select') {
            const opts = (f.options || []).map(o => '<option value="' + escapeHtml(o) + '"' + (o === val ? ' selected' : '') + '>' + escapeHtml(o) + '</option>').join('');
            inputHtml = '<select data-param="' + f.key + '">' + opts + '</select>';
        } else if (f.kind === 'number') {
            inputHtml = '<input type="number" data-param="' + f.key + '" value="' + (typeof val === 'number' ? val : 0) + '">';
        } else if (f.kind === 'array') {
            const txt = Array.isArray(val) ? val.join('\n') : '';
            inputHtml = '<textarea data-param="' + f.key + '" data-kind="array" rows="3" placeholder="One entry per line">' + escapeHtml(txt) + '</textarea>';
        } else {
            inputHtml = '<input type="text" data-param="' + f.key + '" value="' + escapeHtml(String(val)) + '">';
        }

        div.innerHTML = '<label>' + escapeHtml(f.label) + '</label>' + inputHtml +
            (f.hint ? '<div class="param-hint">' + escapeHtml(f.hint) + '</div>' : '');

        /* Live bind */
        const input = div.querySelector('[data-param]');
        input.addEventListener('input', () => {
            if (!taskSequence.steps[selectedIndex]) return;
            if (!taskSequence.steps[selectedIndex].parameters) taskSequence.steps[selectedIndex].parameters = {};
            let v = input.value;
            if (f.kind === 'number') v = parseInt(v, 10) || 0;
            if (f.kind === 'array') v = input.value.split('\n').map(s => s.trim()).filter(Boolean);
            taskSequence.steps[selectedIndex].parameters[f.key] = v;
        });

        $paramFields.appendChild(div);
    });
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
    taskSequence.steps.splice(selectedIndex, 1);
    if (selectedIndex >= taskSequence.steps.length) selectedIndex = taskSequence.steps.length - 1;
    renderStepList();
    selectStep(selectedIndex);
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
        id: addDialogChoice.toLowerCase() + '-' + Date.now(),
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

/* ── Save JSON ────────────────────────────────────────────────────── */
document.getElementById('btnSave').addEventListener('click', () => {
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

/* ── Keyboard shortcuts ───────────────────────────────────────────── */
document.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT' || e.target.isContentEditable) return;
    if (e.key === 'Delete' && selectedIndex >= 0) {
        document.getElementById('btnRemoveStep').click();
    }
});

/* ── Load default task sequence on start ──────────────────────────── */
(function loadDefault() {
    fetch('../TaskSequence/default.json')
        .then(r => { if (!r.ok) throw new Error(r.statusText); return r.json(); })
        .then(data => {
            taskSequence = data;
            $tsName.textContent = taskSequence.name || 'Untitled';
            selectedIndex = taskSequence.steps.length > 0 ? 0 : -1;
            renderStepList();
            selectStep(selectedIndex);
        })
        .catch(() => {
            /* No default file available — start empty */
            renderStepList();
        });
})();
