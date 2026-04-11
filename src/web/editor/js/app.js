/* ─────────────────────────────────────────────────────────────────────
   Nova Task Sequence Editor — app.js
   SCCM-style web UI for building and editing JSON task sequences that
   the Nova engine (Nova.ps1) can read and execute.
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
        description: 'Configure the Windows computer name with naming rules',
        defaults: { computerName: '', namingSource: 'serialNumber', prefix: '', suffix: '', randomDigitCount: 4, maxLength: 15 },
        fields: [
            { key: '_headingStatic', label: 'Static Name', kind: 'heading', hint: 'Assign a fixed name to every device' },
            { key: 'computerName', label: 'Computer name', kind: 'text', hint: 'Fixed name (e.g. RECEPTION-PC). When set, naming pattern rules below are skipped. Editable in the config menu at deploy time.' },
            { key: '_headingPattern', label: 'Naming Pattern', kind: 'heading', hint: 'Build the name dynamically — used when the static name above is empty' },
            { key: 'prefix', label: 'Prefix', kind: 'text', hint: 'Text prepended to the generated base (e.g. AMP-)' },
            { key: 'namingSource', label: 'Naming source', kind: 'select', options: [
                    { value: 'serialNumber', label: 'Serial number' },
                    { value: 'assetTag', label: 'Asset tag' },
                    { value: 'macAddress', label: 'MAC address (last 6 hex)' },
                    { value: 'deviceModel', label: 'Device model' },
                    { value: 'randomDigits', label: 'Random digits' }
                ], hint: 'Device attribute used as the base of the generated name' },
            { key: 'suffix', label: 'Suffix', kind: 'text', hint: 'Text appended to the generated base (e.g. -PC)' },
            { key: 'randomDigitCount', label: 'Random digit count', kind: 'number', hint: 'Number of random digits (default 4)', showWhen: { key: 'namingSource', value: 'randomDigits' } },
            { key: 'maxLength', label: 'Max length', kind: 'number', hint: 'Maximum computer name length (NetBIOS limit is 15)' }
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

/* ── Step help documentation URLs ─────────────────────────────────── */
const STEP_HELP_URLS = {
    PartitionDisk:      'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions',
    DownloadImage:      'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-image-management-command-line-options-s14',
    ApplyImage:         'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/apply-images-using-dism',
    SetBootloader:      'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcdboot-command-line-options-techref-di',
    InjectDrivers:      'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-and-remove-drivers-to-an-offline-windows-image',
    InjectOemDrivers:   'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-and-remove-drivers-to-an-offline-windows-image',
    ImportAutopilot:    'https://learn.microsoft.com/en-us/autopilot/registration-overview',
    ApplyAutopilot:     'https://learn.microsoft.com/en-us/autopilot/existing-devices',
    StageCCMSetup:      'https://learn.microsoft.com/en-us/mem/configmgr/core/clients/deploy/about-client-installation-properties',
    SetComputerName:    'https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-computername',
    SetRegionalSettings:'https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-international-core',
    CustomizeOOBE:      'https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-oobe',
    RunPostScripts:     'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-a-custom-script-to-windows-setup'
};

/* ── Built-in step templates ──────────────────────────────────────── */
const BUILT_IN_STEP_TEMPLATES = [
    {
        id: 'tpl-serial-naming',
        label: 'Serial Number Naming',
        description: 'Name PCs using serial number with AMP- prefix',
        type: 'SetComputerName',
        parameters: { computerName: '', namingSource: 'serialNumber', prefix: 'AMP-', suffix: '', randomDigitCount: 4, maxLength: 15 }
    },
    {
        id: 'tpl-autopilot-full',
        label: 'Autopilot Full Skip',
        description: 'Customize OOBE with all screens skipped for Autopilot',
        type: 'CustomizeOOBE',
        parameters: { unattendSource: 'default', unattendContent: '', unattendUrl: '', unattendPath: '' }
    },
    {
        id: 'tpl-standard-partition',
        label: 'Standard GPT Partition',
        description: 'Partition disk 0 with OS on C: (GPT/UEFI layout)',
        type: 'PartitionDisk',
        parameters: { diskNumber: 0, osDriveLetter: 'C' }
    },
    {
        id: 'tpl-en-us-locale',
        label: 'English (US) Regional',
        description: 'Set all locale settings to en-US for US English',
        type: 'SetRegionalSettings',
        parameters: { inputLocale: 'en-US', systemLocale: 'en-US', userLocale: 'en-US', uiLanguage: 'en-US' }
    },
    {
        id: 'tpl-fr-fr-locale',
        label: 'French (France) Regional',
        description: 'Set all locale settings to fr-FR for French (France)',
        type: 'SetRegionalSettings',
        parameters: { inputLocale: 'fr-FR', systemLocale: 'fr-FR', userLocale: 'fr-FR', uiLanguage: 'fr-FR' }
    }
];

const TEMPLATES_KEY = 'nova_step_templates';

/** Load user-saved templates from localStorage. */
function loadUserTemplates() {
    try {
        const raw = localStorage.getItem(TEMPLATES_KEY);
        return raw ? JSON.parse(raw) : [];
    } catch (_) { return []; }
}

/** Save user templates to localStorage. */
function saveUserTemplates(templates) {
    try { localStorage.setItem(TEMPLATES_KEY, JSON.stringify(templates)); } catch (_) {}
}

/** Get all templates (built-in + user). */
function getAllTemplates() {
    return BUILT_IN_STEP_TEMPLATES.concat(loadUserTemplates());
}

/* ── Default step-type → group mapping ─────────────────────────────── */
const STEP_GROUP_DEFAULTS = {
    SetComputerName:    'Configuration',
    SetRegionalSettings:'Configuration',
    PartitionDisk:      'Disk & Image',
    DownloadImage:      'Disk & Image',
    ApplyImage:         'Disk & Image',
    SetBootloader:      'Disk & Image',
    InjectDrivers:      'Drivers',
    InjectOemDrivers:   'Drivers',
    ImportAutopilot:    'Provisioning',
    ApplyAutopilot:     'Provisioning',
    StageCCMSetup:      'Provisioning',
    CustomizeOOBE:      'Finalization',
    RunPostScripts:     'Finalization'
};

/* ── State ────────────────────────────────────────────────────────── */
let taskSequence = {
    name: 'Default Nova Task Sequence',
    version: '1.0',
    description: 'Standard cloud-native Windows deployment via Nova',
    steps: []
};
let selectedIndex = -1;
let selectedIndices = new Set();
let dragSrcIndex = -1;
let githubConfig = { owner: '', repo: '', clientId: '', oauthProxy: '' };
let currentFilePath = null;
let dirty = false;
let autoSaveTimer = null;
const DRAFT_KEY = 'nova_editor_draft';
const COLLAPSED_KEY = 'nova_collapsed_groups';
let undoStack = [];
let redoStack = [];
const MAX_UNDO = 50;
let lastSnapshot = null;
let jsonRawMode = false;
let collapsedGroups = new Set();

/* Load collapsed-groups state from localStorage */
try {
    const stored = localStorage.getItem(COLLAPSED_KEY);
    if (stored) collapsedGroups = new Set(JSON.parse(stored));
} catch (e) { console.warn('[Nova] Failed to load collapsed groups:', e.message); }

/* ── DOM refs ─────────────────────────────────────────────────────── */
const $stepList     = document.getElementById('stepList');
const $propsEmpty   = document.getElementById('propsEmpty');
const $propsEditor  = document.getElementById('propsEditor');
const $propName     = document.getElementById('propName');
const $propType     = document.getElementById('propType');
const $propDesc     = document.getElementById('propDescription');
const $propEnabled  = document.getElementById('propEnabled');
const $propContErr  = document.getElementById('propContinueOnError');
const $propGroup    = document.getElementById('propGroup');
const $groupSuggestions = document.getElementById('groupSuggestions');
const $paramFields  = document.getElementById('paramFields');
const $tsName       = document.getElementById('tsName');
const $addDialog    = document.getElementById('addStepDialog');
const $addTypeList  = document.getElementById('stepTypeList');
const $addOk        = document.getElementById('btnAddStepOk');
const $fileInput    = document.getElementById('fileInput');
const $validationWarnings = document.getElementById('validationWarnings');
const $btnSave      = document.getElementById('btnSave');
const $btnUndo      = document.getElementById('btnUndo');
const $btnRedo      = document.getElementById('btnRedo');
const $jsonToggle   = document.getElementById('jsonToggle');
const $jsonRawEditor = document.getElementById('jsonRawEditor');
const $jsonRawTextarea = document.getElementById('jsonRawTextarea');
const $jsonRawError = document.getElementById('jsonRawError');
const $stepSearch   = document.getElementById('stepSearch');
const $conditionSection = document.getElementById('conditionSection');
const $condType     = document.getElementById('condType');
const $condFields   = document.getElementById('condFields');
const $btnAddCondition = document.getElementById('btnAddCondition');
const $btnRemoveCondition = document.getElementById('btnRemoveCondition');

/* ── Condition type definitions ───────────────────────────────────── */
const CONDITION_DEFS = {
    variable: {
        label: 'Task Sequence Variable',
        fields: [
            { key: 'variable', label: 'Variable name', kind: 'text', hint: 'Environment or task sequence variable (e.g. FIRMWARE_TYPE, OSDComputerName)' },
            { key: 'operator', label: 'Operator', kind: 'select', options: [
                    { value: 'equals', label: 'Equals' },
                    { value: 'notEquals', label: 'Not equals' },
                    { value: 'contains', label: 'Contains' },
                    { value: 'startsWith', label: 'Starts with' },
                    { value: 'exists', label: 'Exists (is set)' },
                    { value: 'notExists', label: 'Does not exist' }
                ]},
            { key: 'value', label: 'Value', kind: 'text', hint: 'Comparison value', hideWhenOp: ['exists', 'notExists'] }
        ]
    },
    wmiQuery: {
        label: 'WMI Query',
        fields: [
            { key: 'query', label: 'WMI query', kind: 'text', hint: 'WMI query (e.g. SELECT * FROM Win32_ComputerSystem WHERE Model LIKE \'%Virtual%\')' },
            { key: 'namespace', label: 'Namespace', kind: 'text', hint: 'WMI namespace (default: root\\cimv2)' }
        ]
    },
    registry: {
        label: 'Registry Value',
        fields: [
            { key: 'registryPath', label: 'Registry path', kind: 'text', hint: 'Full registry path (e.g. HKLM:\\SOFTWARE\\Microsoft\\Windows)' },
            { key: 'registryValue', label: 'Value name', kind: 'text', hint: 'Registry value name (leave empty to check key existence)' },
            { key: 'operator', label: 'Operator', kind: 'select', options: [
                    { value: 'exists', label: 'Exists' },
                    { value: 'notExists', label: 'Does not exist' },
                    { value: 'equals', label: 'Equals' },
                    { value: 'notEquals', label: 'Not equals' }
                ]},
            { key: 'value', label: 'Expected value', kind: 'text', hint: 'Value to compare against', hideWhenOp: ['exists', 'notExists'] }
        ]
    }
};

/* ── Populate type <select> ───────────────────────────────────────── */
STEP_TYPES.forEach(t => {
    const opt = document.createElement('option');
    opt.value = t.type;
    opt.textContent = t.label;
    $propType.appendChild(opt);
});

/* ── Dirty state tracking ─────────────────────────────────────────── */
function updateDirtyUI() {
    if (dirty) {
        $btnSave.classList.add('dirty');
        document.title = '\u25CF Nova Task Sequence Editor';
    } else {
        $btnSave.classList.remove('dirty');
        document.title = 'Nova Task Sequence Editor';
    }
}

function scheduleDraftSave() {
    clearTimeout(autoSaveTimer);
    autoSaveTimer = setTimeout(function () {
        try { localStorage.setItem(DRAFT_KEY, JSON.stringify(taskSequence)); } catch (e) { console.warn('[Nova] Auto-save draft failed:', e.message); }
    }, 1000);
}

function markDirty() {
    /* Push the pre-mutation snapshot to the undo stack.
       lastSnapshot was taken after the previous operation, so it
       represents the state BEFORE the current mutation. */
    if (lastSnapshot !== null) {
        undoStack.push(lastSnapshot);
        if (undoStack.length > MAX_UNDO) undoStack.shift();
        redoStack.length = 0;
    }
    lastSnapshot = JSON.stringify({ ts: taskSequence, sel: selectedIndex });
    updateUndoRedoUI();
    dirty = true;
    updateDirtyUI();
    scheduleDraftSave();
    renderValidationWarnings();
}

function markClean() {
    dirty = false;
    updateDirtyUI();
    clearTimeout(autoSaveTimer);
    try { localStorage.removeItem(DRAFT_KEY); } catch (_) {}
    resetUndoRedo();
    captureSnapshot();
}

/* ── Undo / Redo ──────────────────────────────────────────────────── */
function captureSnapshot() {
    lastSnapshot = JSON.stringify({ ts: taskSequence, sel: selectedIndex });
}

function applySnapshot(json) {
    const snap = JSON.parse(json);
    taskSequence = snap.ts;
    selectedIndex = snap.sel;
    selectedIndices.clear();
    if (selectedIndex >= 0) selectedIndices.add(selectedIndex);
    $tsName.textContent = taskSequence.name || 'Untitled';
    updateBreadcrumb(taskSequence.name || 'Untitled');
    renderStepList();
    selectStep(selectedIndex);
    lastSnapshot = json;
    dirty = true;
    updateDirtyUI();
    scheduleDraftSave();
}

function undo() {
    if (undoStack.length === 0) return;
    redoStack.push(JSON.stringify({ ts: taskSequence, sel: selectedIndex }));
    applySnapshot(undoStack.pop());
    updateUndoRedoUI();
}

function redo() {
    if (redoStack.length === 0) return;
    undoStack.push(JSON.stringify({ ts: taskSequence, sel: selectedIndex }));
    applySnapshot(redoStack.pop());
    updateUndoRedoUI();
}

function updateUndoRedoUI() {
    if ($btnUndo) $btnUndo.disabled = undoStack.length === 0;
    if ($btnRedo) $btnRedo.disabled = redoStack.length === 0;
}

function resetUndoRedo() {
    undoStack.length = 0;
    redoStack.length = 0;
    lastSnapshot = null;
    updateUndoRedoUI();
}

/* ── Step validation ──────────────────────────────────────────────── */
function validateStep(step) {
    var warnings = [];
    var p = step.parameters || {};
    switch (step.type) {
        case 'PartitionDisk':
            if (p.diskNumber < 0) warnings.push('Disk number must be >= 0');
            break;
        case 'DownloadImage':
            if (!p.edition) warnings.push('Edition is empty');
            break;
        case 'ApplyImage':
            if (!p.edition) warnings.push('Edition is empty');
            break;
        case 'InjectDrivers':
            if (!p.driverPath) warnings.push('Driver path is empty');
            break;
        case 'ApplyAutopilot':
            if (!p.jsonUrl && !p.jsonPath) warnings.push('Either JSON URL or JSON path must be provided');
            break;
        case 'StageCCMSetup':
            if (!p.ccmSetupUrl) warnings.push('CCMSetup URL is empty');
            break;
        case 'SetComputerName':
            if (p.maxLength > 15) warnings.push('Max length exceeds NetBIOS limit of 15');
            break;
        case 'RunPostScripts':
            if (!p.scriptUrls || (Array.isArray(p.scriptUrls) && p.scriptUrls.length === 0)) warnings.push('No script URLs configured');
            break;
    }
    /* Validate condition if present */
    var cond = step.condition;
    if (cond && cond.type) {
        if (cond.type === 'variable' && !cond.variable) {
            warnings.push('Condition: variable name is empty');
        }
        if (cond.type === 'wmiQuery' && !cond.query) {
            warnings.push('Condition: WMI query is empty');
        }
        if (cond.type === 'registry' && !cond.registryPath) {
            warnings.push('Condition: registry path is empty');
        }
    }
    return warnings;
}

function renderValidationWarnings() {
    if (!$validationWarnings) return;
    if (selectedIndex < 0 || !taskSequence.steps[selectedIndex]) {
        $validationWarnings.classList.add('hidden');
        return;
    }
    var warnings = validateStep(taskSequence.steps[selectedIndex]);
    if (warnings.length > 0) {
        $validationWarnings.innerHTML = warnings.map(function (w) {
            return '<div class="validation-warning-item">\u26A0 ' + escapeHtml(w) + '</div>';
        }).join('');
        $validationWarnings.classList.remove('hidden');
    } else {
        $validationWarnings.classList.add('hidden');
    }
}

window.addEventListener('beforeunload', function (e) {
    if (dirty) {
        e.preventDefault();
        e.returnValue = '';
    }
});

/* ── Step tooltip (thumbnail preview) ─────────────────────────────── */
/** Build a multi-line tooltip summarising a step's key parameters. */
function getStepTooltip(step) {
    const parts = [];
    if (step.description) parts.push(step.description);
    const p = step.parameters || {};
    const typeDef = typeMap[step.type];
    if (typeDef && typeDef.fields) {
        typeDef.fields.forEach(f => {
            if (f.kind === 'heading' || f.kind === 'xml') return;
            const val = p[f.key];
            if (val === undefined || val === '' || val === null) return;
            if (Array.isArray(val)) {
                if (val.length > 0) parts.push(f.label + ': ' + val.length + ' item(s)');
            } else {
                const display = typeof val === 'boolean' ? (val ? 'Yes' : 'No') : String(val);
                parts.push(f.label + ': ' + display);
            }
        });
    }
    if (step.condition && step.condition.type) {
        parts.push('Condition: ' + getConditionSummary(step.condition));
    }
    if (step.enabled === false) parts.push('[Disabled]');
    return parts.join('\n');
}

/* ── Render step list ─────────────────────────────────────────────── */
const STEP_BADGE_LABELS = {
    PartitionDisk: 'P', DownloadImage: 'D', ApplyImage: 'A', SetBootloader: 'B',
    InjectDrivers: 'I', InjectOemDrivers: 'O', ApplyAutopilot: 'AP',
    StageCCMSetup: 'S', CustomizeOOBE: 'C', RunPostScripts: 'R',
    SetComputerName: 'CN', SetRegionalSettings: 'RS', ImportAutopilot: 'IA'
};

function saveCollapsedGroups() {
    try { localStorage.setItem(COLLAPSED_KEY, JSON.stringify([...collapsedGroups])); } catch (e) { console.warn('[Nova] Failed to save collapsed groups:', e.message); }
}

function toggleGroup(groupName) {
    if (collapsedGroups.has(groupName)) collapsedGroups.delete(groupName);
    else collapsedGroups.add(groupName);
    saveCollapsedGroups();
    renderStepList();
}

function renderStepList() {
    $stepList.innerHTML = '';
    const filter = ($stepSearch && $stepSearch.value || '').toLowerCase().trim();
    let lastGroup = null;
    taskSequence.steps.forEach((step, i) => {
        /* Apply search filter */
        if (filter) {
            const nameMatch = (step.name || '').toLowerCase().indexOf(filter) >= 0;
            const typeLabel = typeMap[step.type] ? typeMap[step.type].label : step.type;
            const typeMatch = typeLabel.toLowerCase().indexOf(filter) >= 0;
            if (!nameMatch && !typeMatch) return;
        }

        /* Render group header when the group changes */
        const group = step.group || '';
        if (group && group !== lastGroup && !filter) {
            const isCollapsed = collapsedGroups.has(group);
            const header = document.createElement('li');
            header.className = 'step-group-header' + (isCollapsed ? ' collapsed' : '');
            header.dataset.group = group;
            header.innerHTML =
                '<span class="group-chevron">' + (isCollapsed ? '\u25B6' : '\u25BC') + '</span>' +
                '<span class="group-label">' + escapeHtml(group) + '</span>' +
                '<span class="group-count">' + countGroupSteps(group) + '</span>';
            header.addEventListener('click', () => toggleGroup(group));
            /* Allow dropping onto group headers to move steps into that group */
            header.addEventListener('dragover', (e) => { e.preventDefault(); e.dataTransfer.dropEffect = 'move'; header.classList.add('drag-over'); });
            header.addEventListener('dragleave', () => header.classList.remove('drag-over'));
            header.addEventListener('drop', (e) => {
                e.preventDefault();
                header.classList.remove('drag-over');
                if (dragSrcIndex >= 0 && dragSrcIndex < taskSequence.steps.length) {
                    taskSequence.steps[dragSrcIndex].group = group;
                    markDirty();
                    renderStepList();
                }
            });
            $stepList.appendChild(header);
        }
        lastGroup = group;

        /* Skip rendering if group is collapsed (unless filtered or step is selected) */
        if (group && collapsedGroups.has(group) && !filter) return;

        const isPrimary = i === selectedIndex;
        const isMulti = selectedIndices.has(i) && !isPrimary;
        const li = document.createElement('li');
        li.className = 'step-item' +
            (isPrimary ? ' selected' : '') +
            (isMulti ? ' multi-selected' : '') +
            (step.enabled === false ? ' disabled' : '') +
            (group ? ' in-group' : '');
        li.draggable = true;
        li.dataset.index = i;
        li.title = getStepTooltip(step);

        const badge = STEP_BADGE_LABELS[step.type] || '?';
        const stepWarnings = validateStep(step);
        const warnHtml = stepWarnings.length > 0 ? '<span class="step-warning" title="' + escapeHtml(stepWarnings.join('; ')) + '">\u26A0</span>' : '';
        const condHtml = step.condition && step.condition.type
            ? '<span class="step-condition-icon" title="' + escapeHtml(getConditionSummary(step.condition)) + '">\u26A1</span>' : '';

        li.innerHTML =
            '<span class="step-drag-handle" title="Drag to reorder">&#8942;&#8942;</span>' +
            '<span class="step-number">' + (i + 1) + '</span>' +
            '<span class="step-badge" data-type="' + escapeHtml(step.type) + '">' + badge + '</span>' +
            '<div class="step-info">' +
                '<div class="step-title">' + escapeHtml(step.name) + '</div>' +
                '<div class="step-type-label">' + escapeHtml(typeMap[step.type] ? typeMap[step.type].label : step.type) + '</div>' +
            '</div>' + condHtml + warnHtml;

        li.addEventListener('click', (e) => handleStepClick(i, e));

        /* Drag events */
        li.addEventListener('dragstart', onDragStart);
        li.addEventListener('dragover', onDragOver);
        li.addEventListener('dragleave', onDragLeave);
        li.addEventListener('drop', onDrop);
        li.addEventListener('dragend', onDragEnd);

        $stepList.appendChild(li);
    });
}

/** Count how many steps belong to a group. */
function countGroupSteps(groupName) {
    return taskSequence.steps.filter(s => s.group === groupName).length;
}

function handleStepClick(index, e) {
    if (e.ctrlKey || e.metaKey) {
        /* Toggle individual step in multi-selection */
        if (selectedIndices.has(index)) {
            selectedIndices.delete(index);
            if (selectedIndex === index) {
                selectedIndex = selectedIndices.size > 0 ? Math.min(...selectedIndices) : -1;
            }
        } else {
            selectedIndices.add(index);
            selectedIndex = index;
        }
        renderStepList();
        showPropertiesForIndex(selectedIndex);
    } else if (e.shiftKey && selectedIndex >= 0) {
        /* Range selection from current selectedIndex to clicked index */
        const from = Math.min(selectedIndex, index);
        const to = Math.max(selectedIndex, index);
        selectedIndices.clear();
        for (let k = from; k <= to; k++) {
            selectedIndices.add(k);
        }
        renderStepList();
        showPropertiesForIndex(selectedIndex);
    } else {
        /* Normal click — single selection */
        selectStep(index);
    }
}

function showPropertiesForIndex(index) {
    if (index < 0 || index >= taskSequence.steps.length) {
        $propsEmpty.classList.remove('hidden');
        $propsEditor.classList.add('hidden');
        if (jsonRawMode) hideJsonRawView();
        /* Hide condition UI when nothing is selected */
        if ($conditionSection) $conditionSection.classList.add('hidden');
        if ($btnAddCondition) $btnAddCondition.classList.add('hidden');
        return;
    }
    $propsEmpty.classList.add('hidden');
    $propsEditor.classList.remove('hidden');
    const step = taskSequence.steps[index];
    $propName.value = step.name || '';
    $propType.value = step.type || '';
    $propDesc.value = step.description || '';
    $propEnabled.checked = step.enabled !== false;
    $propContErr.checked = step.continueOnError === true;
    $propGroup.value = step.group || '';
    updateGroupSuggestions();
    updateHelpLink(step.type);
    renderConditionUI(step);
    renderValidationWarnings();
    if (jsonRawMode) {
        showJsonRawView();
    } else {
        renderParamFields(step);
    }
}

/** Populate the group datalist with existing group names. */
function updateGroupSuggestions() {
    if (!$groupSuggestions) return;
    const groups = new Set();
    taskSequence.steps.forEach(s => { if (s.group) groups.add(s.group); });
    $groupSuggestions.innerHTML = '';
    groups.forEach(g => {
        const opt = document.createElement('option');
        opt.value = g;
        $groupSuggestions.appendChild(opt);
    });
}

/** Show or hide the documentation help link for the current step type. */
function updateHelpLink(stepType) {
    const $link = document.getElementById('helpLink');
    if (!$link) return;
    const url = STEP_HELP_URLS[stepType];
    if (url) {
        $link.href = url;
        $link.classList.remove('hidden');
    } else {
        $link.classList.add('hidden');
    }
}

/* ── Condition UI ─────────────────────────────────────────────────── */

/** Render the condition UI section for the currently selected step. */
function renderConditionUI(step) {
    if (!$conditionSection || !$btnAddCondition) return;
    if (step.condition && step.condition.type) {
        /* Show condition editor */
        $conditionSection.classList.remove('hidden');
        $btnAddCondition.classList.add('hidden');
        $condType.value = step.condition.type;
        renderConditionFields(step.condition);
    } else {
        /* Show "Add Condition" button */
        $conditionSection.classList.add('hidden');
        $btnAddCondition.classList.remove('hidden');
    }
}

/** Render type-specific fields inside the condition body. */
function renderConditionFields(condition) {
    $condFields.innerHTML = '';
    const def = CONDITION_DEFS[condition.type];
    if (!def) return;

    def.fields.forEach(f => {
        const div = document.createElement('div');
        div.className = 'condition-field';
        div.dataset.condKey = f.key;

        let inputHtml = '';
        const val = condition[f.key] !== undefined ? condition[f.key] : '';

        if (f.kind === 'select') {
            const opts = f.options.map(o => {
                const optVal = typeof o === 'object' ? o.value : o;
                const optLabel = typeof o === 'object' ? o.label : o;
                return '<option value="' + escapeHtml(optVal) + '"' + (optVal === val ? ' selected' : '') + '>' + escapeHtml(optLabel) + '</option>';
            }).join('');
            inputHtml = '<select data-cond-key="' + f.key + '">' + opts + '</select>';
        } else {
            inputHtml = '<input type="text" data-cond-key="' + f.key + '" value="' + escapeHtml(String(val)) + '"' +
                (f.hint ? ' placeholder="' + escapeHtml(f.hint) + '"' : '') + '>';
        }

        div.innerHTML = '<label>' + escapeHtml(f.label) + '</label>' + inputHtml +
            (f.hint ? '<div class="cond-hint">' + escapeHtml(f.hint) + '</div>' : '');

        const input = div.querySelector('[data-cond-key]');
        const evtType = f.kind === 'select' ? 'change' : 'input';
        input.addEventListener(evtType, () => {
            if (selectedIndex < 0 || !taskSequence.steps[selectedIndex]) return;
            const step = taskSequence.steps[selectedIndex];
            if (!step.condition) return;
            step.condition[f.key] = input.value;
            markDirty();
            renderStepList();
            /* Re-evaluate hideWhenOp visibility when operator changes */
            if (f.key === 'operator') applyConditionVisibility(condition);
        });

        $condFields.appendChild(div);
    });

    applyConditionVisibility(condition);
}

/** Hide/show condition fields based on the current operator (hideWhenOp). */
function applyConditionVisibility(condition) {
    const def = CONDITION_DEFS[condition.type];
    if (!def) return;
    const operatorVal = condition.operator || '';
    def.fields.forEach(f => {
        if (!f.hideWhenOp) return;
        const fieldDiv = $condFields.querySelector('[data-cond-key="' + f.key + '"]');
        if (!fieldDiv) return;
        const wrapper = fieldDiv.closest('.condition-field');
        if (wrapper) wrapper.classList.toggle('hidden', f.hideWhenOp.indexOf(operatorVal) >= 0);
    });
}

/** Build a human-readable summary of a condition for tooltips. */
function getConditionSummary(condition) {
    if (!condition || !condition.type) return '';
    switch (condition.type) {
        case 'variable': {
            const v = condition.variable || '?';
            const op = condition.operator || 'equals';
            if (op === 'exists') return 'If $' + v + ' exists';
            if (op === 'notExists') return 'If $' + v + ' does not exist';
            return 'If $' + v + ' ' + op + ' "' + (condition.value || '') + '"';
        }
        case 'wmiQuery':
            return 'If WMI query returns results';
        case 'registry': {
            const path = condition.registryPath || '?';
            const op = condition.operator || 'exists';
            if (op === 'exists') return 'If ' + path + ' exists';
            if (op === 'notExists') return 'If ' + path + ' does not exist';
            return 'If ' + path + ' ' + op + ' "' + (condition.value || '') + '"';
        }
        default:
            return 'Conditional step';
    }
}

/* Condition button event handlers */
if ($btnAddCondition) {
    $btnAddCondition.addEventListener('click', () => {
        if (selectedIndex < 0 || !taskSequence.steps[selectedIndex]) return;
        const step = taskSequence.steps[selectedIndex];
        step.condition = { type: 'variable', variable: '', operator: 'equals', value: '' };
        markDirty();
        renderConditionUI(step);
        renderStepList();
    });
}

if ($btnRemoveCondition) {
    $btnRemoveCondition.addEventListener('click', () => {
        if (selectedIndex < 0 || !taskSequence.steps[selectedIndex]) return;
        delete taskSequence.steps[selectedIndex].condition;
        markDirty();
        renderConditionUI(taskSequence.steps[selectedIndex]);
        renderStepList();
    });
}

if ($condType) {
    $condType.addEventListener('change', () => {
        if (selectedIndex < 0 || !taskSequence.steps[selectedIndex]) return;
        const step = taskSequence.steps[selectedIndex];
        const newType = $condType.value;
        /* Reset condition fields when type changes */
        const defaults = {
            variable: { type: 'variable', variable: '', operator: 'equals', value: '' },
            wmiQuery: { type: 'wmiQuery', query: '', namespace: '' },
            registry: { type: 'registry', registryPath: '', registryValue: '', operator: 'exists', value: '' }
        };
        step.condition = defaults[newType] || { type: newType };
        markDirty();
        renderConditionFields(step.condition);
        renderStepList();
    });
}

function scrollStepIntoView(index) {
    const items = $stepList.querySelectorAll('.step-item');
    for (let j = 0; j < items.length; j++) {
        if (parseInt(items[j].dataset.index, 10) === index) {
            items[j].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
            break;
        }
    }
}

/* ── Select step ──────────────────────────────────────────────────── */
function selectStep(index) {
    selectedIndex = index;
    selectedIndices.clear();
    if (index >= 0) selectedIndices.add(index);
    renderStepList();
    showPropertiesForIndex(index);
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
        div.className = 'param-field' + (f.kind === 'array' ? ' param-field-array' : '') + (f.kind === 'xml' ? ' param-field-xml' : '') + (f.kind === 'heading' ? ' param-field-heading' : '');

        let inputHtml = '';
        if (f.kind === 'heading') {
            div.innerHTML = '<span class="param-heading-text">' + escapeHtml(f.label) + '</span>' +
                (f.hint ? '<div class="param-hint">' + escapeHtml(f.hint) + '</div>' : '');
            fieldWrappers.push({ div: div, field: f });
            $paramFields.appendChild(div);
            return; /* headings have no input — skip binding */
        } else if (f.kind === 'select') {
            const opts = (f.options || []).map(o => {
                const optVal = typeof o === 'object' ? o.value : o;
                const optLabel = typeof o === 'object' ? o.label : o;
                return '<option value="' + escapeHtml(optVal) + '"' + (optVal === val ? ' selected' : '') + '>' + escapeHtml(optLabel) + '</option>';
            }).join('');
            inputHtml = '<select data-param="' + f.key + '">' + opts + '</select>';
        } else if (f.kind === 'number') {
            inputHtml = '<input type="number" data-param="' + f.key + '" value="' + (typeof val === 'number' ? val : 0) + '">';
        } else if (f.kind === 'array') {
            const txt = Array.isArray(val) ? val.join('\n') : '';
            inputHtml = '<textarea data-param="' + f.key + '" data-kind="array" rows="3" placeholder="One entry per line">' + escapeHtml(txt) + '</textarea>';
        } else if (f.kind === 'xml') {
            inputHtml = '<div class="xml-view-toggle">' +
                '<button type="button" class="xml-view-btn active" data-view="visual" title="Form-based visual editor">&#9998; Visual</button>' +
                '<button type="button" class="xml-view-btn" data-view="xml" title="Raw XML editor">&lt;/&gt; XML</button>' +
                '</div>' +
                '<div class="visual-unattend-builder" data-param-key="' + f.key + '"></div>' +
                '<div class="xml-editor-raw" style="display:none;">' +
                '<div class="xml-editor-toolbar">' +
                '<button type="button" class="xml-tb-btn" data-action="format" title="Format / indent XML">&#9998; Format</button>' +
                '<button type="button" class="xml-tb-btn" data-action="validate" title="Check XML syntax">&#10003; Validate</button>' +
                '<button type="button" class="xml-tb-btn" data-action="reset" title="Reset to default unattend.xml">&#8634; Reset</button>' +
                '</div>' +
                '<div class="xml-editor-body">' +
                '<div class="xml-line-numbers" aria-hidden="true"></div>' +
                '<textarea data-param="' + f.key + '" data-kind="xml" rows="14" spellcheck="false" wrap="off">' + escapeHtml(String(val)) + '</textarea>' +
                '</div>' +
                '<div class="xml-validation"></div>' +
                '</div>';
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
            markDirty();

            /* Re-evaluate showWhen visibility when a select changes */
            if (f.kind === 'select') applyShowWhen();

            /* Sync step values into unattend.xml when steps that touch it change */
            const stepType = taskSequence.steps[selectedIndex].type;
            if (stepType === 'SetComputerName' || stepType === 'SetRegionalSettings') {
                syncUnattendContent();
            }
        });

        /* Enhanced XML editor (toolbar, line numbers, tab-indent, visual builder) */
        if (f.kind === 'xml') {
            setupXmlEditor(div, input);
            setupVisualUnattendBuilder(div, input, step);
        }

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
            div.classList.toggle('hidden', depVal !== field.showWhen.value);
        });
    }
    applyShowWhen();
}

/* ── Property change handlers ─────────────────────────────────────── */
$propName.addEventListener('input', () => {
    if (selectedIndex < 0) return;
    taskSequence.steps[selectedIndex].name = $propName.value;
    markDirty();
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
    markDirty();
    selectStep(selectedIndex);
    renderStepList();
});
$propDesc.addEventListener('input', () => {
    if (selectedIndex < 0) return;
    taskSequence.steps[selectedIndex].description = $propDesc.value;
    markDirty();
});
$propEnabled.addEventListener('change', () => {
    if (selectedIndex < 0) return;
    taskSequence.steps[selectedIndex].enabled = $propEnabled.checked;
    markDirty();
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
    markDirty();
});
$propGroup.addEventListener('input', () => {
    if (selectedIndex < 0) return;
    const val = $propGroup.value.trim();
    if (val) {
        taskSequence.steps[selectedIndex].group = val;
    } else {
        delete taskSequence.steps[selectedIndex].group;
    }
    markDirty();
    renderStepList();
});
$tsName.addEventListener('input', () => {
    taskSequence.name = $tsName.textContent.trim();
    updateBreadcrumb(taskSequence.name);
    markDirty();
});

/* ── Drag-and-drop reorder ────────────────────────────────────────── */
function onDragStart(e) {
    dragSrcIndex = parseInt(e.currentTarget.dataset.index, 10);
    e.dataTransfer.effectAllowed = 'move';
    e.currentTarget.classList.add('dragging');
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
    markDirty();
    renderStepList();
    selectStep(selectedIndex);
}
function onDragEnd(e) {
    e.currentTarget.classList.remove('dragging');
    document.querySelectorAll('.step-item').forEach(el => el.classList.remove('drag-over'));
}

/* ── Move up / down ───────────────────────────────────────────────── */
document.getElementById('btnMoveUp').addEventListener('click', () => {
    if (selectedIndex <= 0) return;
    const tmp = taskSequence.steps[selectedIndex - 1];
    taskSequence.steps[selectedIndex - 1] = taskSequence.steps[selectedIndex];
    taskSequence.steps[selectedIndex] = tmp;
    selectedIndex--;
    markDirty();
    renderStepList();
    selectStep(selectedIndex);
});
document.getElementById('btnMoveDown').addEventListener('click', () => {
    if (selectedIndex < 0 || selectedIndex >= taskSequence.steps.length - 1) return;
    const tmp = taskSequence.steps[selectedIndex + 1];
    taskSequence.steps[selectedIndex + 1] = taskSequence.steps[selectedIndex];
    taskSequence.steps[selectedIndex] = tmp;
    selectedIndex++;
    markDirty();
    renderStepList();
    selectStep(selectedIndex);
});

/* ── Remove step ──────────────────────────────────────────────────── */
document.getElementById('btnRemoveStep').addEventListener('click', () => {
    if (selectedIndex < 0) return;
    let needSync = false;
    if (selectedIndices.size > 1) {
        /* Bulk delete — remove all selected steps (iterate in reverse to preserve indices) */
        const sorted = Array.from(selectedIndices).sort((a, b) => b - a);
        sorted.forEach((idx) => {
            if (idx >= 0 && idx < taskSequence.steps.length) {
                const t = taskSequence.steps[idx].type;
                if (t === 'SetComputerName' || t === 'SetRegionalSettings') needSync = true;
                taskSequence.steps.splice(idx, 1);
            }
        });
        selectedIndex = Math.min(sorted[sorted.length - 1], taskSequence.steps.length - 1);
    } else {
        const removedType = taskSequence.steps[selectedIndex].type;
        if (removedType === 'SetComputerName' || removedType === 'SetRegionalSettings') needSync = true;
        taskSequence.steps.splice(selectedIndex, 1);
        if (selectedIndex >= taskSequence.steps.length) selectedIndex = taskSequence.steps.length - 1;
    }
    markDirty();
    renderStepList();
    selectStep(selectedIndex);
    if (needSync) syncUnattendContent();
});

/* ── Add step dialog ──────────────────────────────────────────────── */
let addDialogChoice = null;
let addDialogTemplate = null;  /* Holds the template object when a template is selected */
const $templateList = document.getElementById('templateList');
const $noTemplates = document.getElementById('noTemplates');

/** Render the template list in the Add Step dialog. */
function renderTemplateList() {
    if (!$templateList) return;
    $templateList.innerHTML = '';
    const templates = getAllTemplates();
    if (templates.length === 0) {
        if ($noTemplates) $noTemplates.classList.remove('hidden');
        return;
    }
    if ($noTemplates) $noTemplates.classList.add('hidden');
    templates.forEach(tpl => {
        const li = document.createElement('li');
        const badge = STEP_BADGE_LABELS[tpl.type] || '?';
        const isUser = !BUILT_IN_STEP_TEMPLATES.some(b => b.id === tpl.id);
        li.innerHTML =
            '<div class="st-name">' +
                '<span class="step-badge st-badge-inline" data-type="' + escapeHtml(tpl.type) + '">' + badge + '</span> ' +
                escapeHtml(tpl.label) +
                (isUser ? '<button class="tpl-delete-btn" data-tpl-id="' + escapeHtml(tpl.id) + '" title="Delete template">&#10005;</button>' : '') +
            '</div>' +
            '<div class="st-desc">' + escapeHtml(tpl.description) + '</div>';
        li.addEventListener('click', (e) => {
            if (e.target.classList.contains('tpl-delete-btn')) return; /* handled below */
            $templateList.querySelectorAll('li').forEach(el => el.classList.remove('selected'));
            $addTypeList.querySelectorAll('li').forEach(el => el.classList.remove('selected'));
            li.classList.add('selected');
            addDialogChoice = tpl.type;
            addDialogTemplate = tpl;
            $addOk.disabled = false;
        });
        /* Delete button for user templates */
        const delBtn = li.querySelector('.tpl-delete-btn');
        if (delBtn) {
            delBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                const userTemplates = loadUserTemplates().filter(t => t.id !== tpl.id);
                saveUserTemplates(userTemplates);
                addDialogTemplate = null;
                addDialogChoice = null;
                $addOk.disabled = true;
                renderTemplateList();
            });
        }
        $templateList.appendChild(li);
    });
}

/* Tab switching in the Add Step dialog */
document.querySelectorAll('.dialog-tab').forEach(tab => {
    tab.addEventListener('click', () => {
        document.querySelectorAll('.dialog-tab').forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        const target = tab.dataset.tab;
        document.getElementById('tabTypes').classList.toggle('hidden', target !== 'types');
        document.getElementById('tabTemplates').classList.toggle('hidden', target !== 'templates');
        /* Clear selection when switching tabs */
        addDialogChoice = null;
        addDialogTemplate = null;
        $addOk.disabled = true;
        $addTypeList.querySelectorAll('li').forEach(el => el.classList.remove('selected'));
        if ($templateList) $templateList.querySelectorAll('li').forEach(el => el.classList.remove('selected'));
        if (target === 'templates') renderTemplateList();
    });
});

document.getElementById('btnAddStep').addEventListener('click', () => {
    addDialogChoice = null;
    addDialogTemplate = null;
    $addOk.disabled = true;
    /* Reset to Step Types tab */
    document.querySelectorAll('.dialog-tab').forEach(t => t.classList.remove('active'));
    const typesTab = document.querySelector('.dialog-tab[data-tab="types"]');
    if (typesTab) typesTab.classList.add('active');
    document.getElementById('tabTypes').classList.remove('hidden');
    document.getElementById('tabTemplates').classList.add('hidden');
    $addTypeList.innerHTML = '';
    STEP_TYPES.forEach(t => {
        const li = document.createElement('li');
        li.innerHTML = '<div class="st-name">' + escapeHtml(t.label) + '</div>' +
                       '<div class="st-desc">' + escapeHtml(t.description) + '</div>';
        li.addEventListener('click', () => {
            $addTypeList.querySelectorAll('li').forEach(el => el.classList.remove('selected'));
            if ($templateList) $templateList.querySelectorAll('li').forEach(el => el.classList.remove('selected'));
            li.classList.add('selected');
            addDialogChoice = t.type;
            addDialogTemplate = null;
            $addOk.disabled = false;
        });
        $addTypeList.appendChild(li);
    });
    $addDialog.classList.remove('hidden');
});
document.getElementById('btnAddStepCancel').addEventListener('click', () => { $addDialog.classList.add('hidden'); });
$addOk.addEventListener('click', () => {
    if (!addDialogChoice) return;
    $addDialog.classList.add('hidden');
    const def = typeMap[addDialogChoice];
    const newStep = {
        id: generateStepId(addDialogChoice),
        name: addDialogTemplate ? addDialogTemplate.label : def.label,
        type: addDialogChoice,
        enabled: true,
        description: addDialogTemplate ? addDialogTemplate.description : def.description,
        continueOnError: false,
        parameters: addDialogTemplate ? structuredClone(addDialogTemplate.parameters) : structuredClone(def.defaults)
    };
    /* Inherit group from the selected step, or use the type default */
    if (selectedIndex >= 0 && taskSequence.steps[selectedIndex] && taskSequence.steps[selectedIndex].group) {
        newStep.group = taskSequence.steps[selectedIndex].group;
    } else if (STEP_GROUP_DEFAULTS[addDialogChoice]) {
        newStep.group = STEP_GROUP_DEFAULTS[addDialogChoice];
    }
    const insertAt = selectedIndex >= 0 ? selectedIndex + 1 : taskSequence.steps.length;
    taskSequence.steps.splice(insertAt, 0, newStep);
    selectedIndex = insertAt;
    addDialogTemplate = null;
    markDirty();
    renderStepList();
    selectStep(selectedIndex);
    if (addDialogChoice === 'SetComputerName' || addDialogChoice === 'SetRegionalSettings') {
        syncUnattendContent();
    }
});

/* ── Save step as template ────────────────────────────────────────── */
document.getElementById('btnSaveTemplate').addEventListener('click', () => {
    if (selectedIndex < 0 || !taskSequence.steps[selectedIndex]) return;
    const step = taskSequence.steps[selectedIndex];
    const name = prompt('Template name:', step.name || 'My Template');
    if (!name || !name.trim()) return;
    const userTemplates = loadUserTemplates();
    userTemplates.push({
        id: 'user-tpl-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 6),
        label: name.trim(),
        description: step.description || (typeMap[step.type] ? typeMap[step.type].description : ''),
        type: step.type,
        parameters: structuredClone(step.parameters || {})
    });
    saveUserTemplates(userTemplates);
});

/* ── New ──────────────────────────────────────────────────────────── */
document.getElementById('btnNew').addEventListener('click', () => {
    if (!confirm('Create a new empty task sequence? Unsaved changes will be lost.')) return;
    taskSequence = { name: 'New Task Sequence', version: '1.0', description: '', steps: [] };
    currentFilePath = null;
    $tsName.textContent = taskSequence.name;
    selectedIndex = -1;
    renderStepList();
    selectStep(-1);
    markClean();
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
            currentFilePath = null;

            /* Fill empty unattendContent from the repo file */
            populateDefaultUnattendContent(taskSequence.steps);

            /* Sync step values (SetComputerName, SetRegionalSettings) into unattend.xml */
            syncUnattendContent();

            $tsName.textContent = taskSequence.name || 'Untitled';
            selectedIndex = taskSequence.steps.length > 0 ? 0 : -1;
            renderStepList();
            selectStep(selectedIndex);
            markClean();
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
                sessionStorage.setItem('nova_github_token', v);
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
                sessionStorage.setItem('nova_github_token', data.access_token);
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
            console.warn('[Nova] Device Flow token poll error:', err);
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
        var existing = sessionStorage.getItem('nova_github_token');
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
                console.warn('[Nova] GitHub Device Flow failed, falling back to PAT.', err);
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
        /* Use tracked file path for existing files, or derive from task sequence name for new ones */
        let path = currentFilePath;
        if (!path) {
            const safeName = (taskSequence.name || 'tasksequence').replace(/[^a-zA-Z0-9_-]/g, '_').substring(0, 60);
            path = 'resources/task-sequence/' + safeName + '.json';
        }
        const apiBase = 'https://api.github.com/repos/' + encodeURIComponent(githubConfig.owner) + '/' + encodeURIComponent(githubConfig.repo) + '/contents/' + path;
        const headers = { 'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github.v3+json' };

        /* Try to get current SHA (may be 404 for new files) */
        const getResp = await fetch(apiBase, { headers: headers });
        if (getResp.status === 401 || getResp.status === 403) {
            sessionStorage.removeItem('nova_github_token');
            throw new Error('Invalid or expired GitHub token. Please try saving again.');
        }
        let existingSha = null;
        if (getResp.ok) {
            const fileData = await getResp.json();
            existingSha = fileData.sha;
        } else if (getResp.status !== 404) {
            throw new Error('Failed to read file from GitHub (HTTP ' + getResp.status + ')');
        }

        /* Create or update file */
        const putBody = {
            message: (existingSha ? 'Update ' : 'Create ') + path.split('/').pop() + ' via Nova Editor',
            content: toBase64(json)
        };
        if (existingSha) putBody.sha = existingSha;
        const putResp = await fetch(apiBase, {
            method: 'PUT',
            headers: Object.assign({ 'Content-Type': 'application/json' }, headers),
            body: JSON.stringify(putBody)
        });
        if (putResp.status === 401 || putResp.status === 403) {
            sessionStorage.removeItem('nova_github_token');
            throw new Error('GitHub token lacks write permission. Please try saving again with a valid token.');
        }
        if (!putResp.ok) {
            const errBody = await putResp.json().catch(function () { return {}; });
            throw new Error(errBody.message || 'GitHub API error (HTTP ' + putResp.status + ')');
        }

        currentFilePath = path;
        btnSave.textContent = '\u2705 Saved';
        markClean();
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

/* ── Pre-flight task sequence validation ──────────────────────────── */

/**
 * Run a full set of pre-flight checks on the task sequence.
 * Returns an array of { level: 'error'|'warning'|'pass', message: string }.
 */
function validateTaskSequence() {
    var results = [];
    var steps = taskSequence.steps || [];
    var enabled = steps.filter(function (s) { return s.enabled !== false; });

    if (steps.length === 0) {
        results.push({ level: 'warning', message: 'Task sequence has no steps' });
        return results;
    }

    /* Helper: find the first enabled step index of a given type */
    function firstEnabled(type) {
        for (var i = 0; i < steps.length; i++) {
            if (steps[i].type === type && steps[i].enabled !== false) return i;
        }
        return -1;
    }

    /* ── Required steps ─────────────────────────────────────────────── */
    var partIdx   = firstEnabled('PartitionDisk');
    var applyIdx  = firstEnabled('ApplyImage');
    var bootIdx   = firstEnabled('SetBootloader');
    var dlIdx     = firstEnabled('DownloadImage');
    var cnIdx     = firstEnabled('SetComputerName');
    var rsIdx     = firstEnabled('SetRegionalSettings');
    var oobeIdx   = firstEnabled('CustomizeOOBE');

    if (applyIdx >= 0 && partIdx < 0) {
        results.push({ level: 'error', message: 'ApplyImage is enabled but no PartitionDisk step is enabled — disk must be partitioned first' });
    }
    if (bootIdx >= 0 && applyIdx < 0) {
        results.push({ level: 'warning', message: 'SetBootloader is enabled but no ApplyImage step is enabled' });
    }

    /* ── Step ordering ──────────────────────────────────────────────── */
    if (partIdx >= 0 && applyIdx >= 0 && partIdx > applyIdx) {
        results.push({ level: 'error', message: 'PartitionDisk (step ' + (partIdx + 1) + ') should come before ApplyImage (step ' + (applyIdx + 1) + ')' });
    }
    if (dlIdx >= 0 && applyIdx >= 0 && dlIdx > applyIdx) {
        results.push({ level: 'warning', message: 'DownloadImage (step ' + (dlIdx + 1) + ') should come before ApplyImage (step ' + (applyIdx + 1) + ')' });
    }
    if (applyIdx >= 0 && bootIdx >= 0 && bootIdx < applyIdx) {
        results.push({ level: 'warning', message: 'SetBootloader (step ' + (bootIdx + 1) + ') should come after ApplyImage (step ' + (applyIdx + 1) + ')' });
    }
    if (cnIdx >= 0 && oobeIdx >= 0 && cnIdx > oobeIdx) {
        results.push({ level: 'warning', message: 'SetComputerName (step ' + (cnIdx + 1) + ') should come before CustomizeOOBE (step ' + (oobeIdx + 1) + ') for proper XML sync' });
    }
    if (rsIdx >= 0 && oobeIdx >= 0 && rsIdx > oobeIdx) {
        results.push({ level: 'warning', message: 'SetRegionalSettings (step ' + (rsIdx + 1) + ') should come before CustomizeOOBE (step ' + (oobeIdx + 1) + ') for proper XML sync' });
    }

    /* ── Duplicate IDs ──────────────────────────────────────────────── */
    var idsSeen = {};
    steps.forEach(function (s, i) {
        if (s.id) {
            if (idsSeen[s.id] !== undefined) {
                results.push({ level: 'error', message: 'Duplicate step ID "' + s.id + '" on steps ' + (idsSeen[s.id] + 1) + ' and ' + (i + 1) });
            } else {
                idsSeen[s.id] = i;
            }
        }
    });

    /* ── Empty names ────────────────────────────────────────────────── */
    steps.forEach(function (s, i) {
        if (!s.name || !s.name.trim()) {
            results.push({ level: 'warning', message: 'Step ' + (i + 1) + ' has an empty name' });
        }
    });

    /* ── Per-step validation warnings ───────────────────────────────── */
    steps.forEach(function (s, i) {
        if (s.enabled === false) return;
        var warnings = validateStep(s);
        warnings.forEach(function (w) {
            results.push({ level: 'warning', message: 'Step ' + (i + 1) + ' (' + escapeHtml(s.name || s.type) + '): ' + w });
        });
    });

    /* ── All passed ─────────────────────────────────────────────────── */
    if (results.length === 0) {
        results.push({ level: 'pass', message: 'All pre-flight checks passed — task sequence is ready for deployment' });
    }

    return results;
}

/**
 * Show the validation report in a modal dialog.
 */
function showValidationReport(results) {
    var overlay = document.createElement('div');
    overlay.className = 'dialog-overlay';
    var dialog = document.createElement('div');
    dialog.className = 'dialog validation-report-dialog';

    var errors   = results.filter(function (r) { return r.level === 'error'; }).length;
    var warnings = results.filter(function (r) { return r.level === 'warning'; }).length;
    var passes   = results.filter(function (r) { return r.level === 'pass'; }).length;

    var summaryClass = errors > 0 ? 'vr-summary-error' : (warnings > 0 ? 'vr-summary-warning' : 'vr-summary-pass');
    var summaryText  = errors > 0
        ? errors + ' error' + (errors > 1 ? 's' : '') + (warnings ? ', ' + warnings + ' warning' + (warnings > 1 ? 's' : '') : '')
        : warnings > 0
            ? warnings + ' warning' + (warnings > 1 ? 's' : '')
            : 'All checks passed';

    var html = '<h2>&#9989; Validation Report</h2>';
    html += '<div class="vr-summary ' + summaryClass + '">' + summaryText + '</div>';
    html += '<ul class="vr-list">';
    results.forEach(function (r) {
        var icon = r.level === 'error' ? '\u2717' : (r.level === 'warning' ? '\u26A0' : '\u2713');
        html += '<li class="vr-item vr-' + r.level + '">' +
            '<span class="vr-icon">' + icon + '</span>' +
            '<span class="vr-msg">' + r.message + '</span>' +
            '</li>';
    });
    html += '</ul>';
    html += '<div class="dialog-actions"><button class="btn btn-primary" id="vrClose">Close</button></div>';

    dialog.innerHTML = html;
    overlay.appendChild(dialog);
    document.body.appendChild(overlay);

    document.getElementById('vrClose').addEventListener('click', function () {
        document.body.removeChild(overlay);
    });
    overlay.addEventListener('click', function (e) {
        if (e.target === overlay) document.body.removeChild(overlay);
    });
}

document.getElementById('btnValidate').addEventListener('click', function () {
    var results = validateTaskSequence();
    showValidationReport(results);
});

/* ── Utils ────────────────────────────────────────────────────────── */
function generateStepId(type) {
    return (type || 'step').toLowerCase() + '-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
}
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

/* ── Visual Unattend Builder ───────────────────────────────────────── */

/** OOBE settings definition for the visual builder form. */
const OOBE_VISUAL_FIELDS = [
    { key: 'HideEULAPage',                kind: 'checkbox', label: 'Hide EULA Page',                 hint: 'Skip the End User License Agreement screen', defaultVal: true },
    { key: 'HideOEMRegistrationScreen',    kind: 'checkbox', label: 'Hide OEM Registration',          hint: 'Skip the OEM registration screen', defaultVal: true },
    { key: 'HideOnlineAccountScreens',     kind: 'checkbox', label: 'Hide Online Account Screens',    hint: 'Skip Microsoft account sign-in prompts', defaultVal: false },
    { key: 'HideWirelessSetupInOOBE',      kind: 'checkbox', label: 'Hide Wireless Setup',            hint: 'Skip the Wi-Fi network selection screen', defaultVal: false },
    { key: 'ProtectYourPC',                kind: 'select',   label: 'Express Settings (ProtectYourPC)', hint: 'Controls how Windows handles telemetry/privacy',
        options: [
            { value: '1', label: '1 — Use recommended settings' },
            { value: '2', label: '2 — Install updates only' },
            { value: '3', label: '3 — Skip (enterprise recommended)' }
        ], defaultVal: '3' },
    { key: 'SkipMachineOOBE',              kind: 'checkbox', label: 'Skip Machine OOBE',              hint: 'Skip the machine-level out-of-box experience', defaultVal: false },
    { key: 'SkipUserOOBE',                 kind: 'checkbox', label: 'Skip User OOBE',                 hint: 'Skip the user-level out-of-box experience', defaultVal: false }
];

/** Pre-built unattend templates for common deployment scenarios. */
const UNATTEND_TEMPLATES = [
    {
        id: 'default',
        label: 'Default',
        description: 'Standard defaults — hide EULA and OEM, use enterprise express settings',
        values: { HideEULAPage: 'true', HideOEMRegistrationScreen: 'true', HideOnlineAccountScreens: 'false', HideWirelessSetupInOOBE: 'false', ProtectYourPC: '3', SkipMachineOOBE: 'false', SkipUserOOBE: 'false' }
    },
    {
        id: 'autopilot',
        label: 'Autopilot',
        description: 'Skip everything — Autopilot / Intune handles the entire OOBE flow',
        values: { HideEULAPage: 'true', HideOEMRegistrationScreen: 'true', HideOnlineAccountScreens: 'true', HideWirelessSetupInOOBE: 'true', ProtectYourPC: '3', SkipMachineOOBE: 'true', SkipUserOOBE: 'true' }
    },
    {
        id: 'enterprise',
        label: 'Enterprise',
        description: 'Enterprise standard — hide EULA, OEM, wireless; skip machine OOBE',
        values: { HideEULAPage: 'true', HideOEMRegistrationScreen: 'true', HideOnlineAccountScreens: 'false', HideWirelessSetupInOOBE: 'true', ProtectYourPC: '3', SkipMachineOOBE: 'true', SkipUserOOBE: 'false' }
    },
    {
        id: 'kiosk',
        label: 'Kiosk',
        description: 'Kiosk / shared device — skip machine OOBE, keep user sign-in for assigned access',
        values: { HideEULAPage: 'true', HideOEMRegistrationScreen: 'true', HideOnlineAccountScreens: 'false', HideWirelessSetupInOOBE: 'true', ProtectYourPC: '3', SkipMachineOOBE: 'true', SkipUserOOBE: 'false' }
    },
    {
        id: 'minimal',
        label: 'Minimal',
        description: 'Minimal intervention — only hide EULA, keep other prompts visible',
        values: { HideEULAPage: 'true', HideOEMRegistrationScreen: 'false', HideOnlineAccountScreens: 'false', HideWirelessSetupInOOBE: 'false', ProtectYourPC: '1', SkipMachineOOBE: 'false', SkipUserOOBE: 'false' }
    }
];

/**
 * Parse OOBE settings from unattend XML string.
 * Returns an object with setting keys and their current values from the XML.
 */
function parseOobeSettingsFromXml(xml) {
    const result = {};
    if (!xml || !xml.trim()) return result;
    try {
        const doc = new DOMParser().parseFromString(xml, 'application/xml');
        if (doc.querySelector('parsererror')) return result;

        /* Find the oobeSystem pass → Shell-Setup component → OOBE element */
        for (let settings = doc.documentElement.firstElementChild; settings; settings = settings.nextElementSibling) {
            if (settings.localName !== 'settings' || settings.getAttribute('pass') !== 'oobeSystem') continue;
            for (let comp = settings.firstElementChild; comp; comp = comp.nextElementSibling) {
                if (comp.localName !== 'component' || comp.getAttribute('name') !== 'Microsoft-Windows-Shell-Setup') continue;
                for (let oobe = comp.firstElementChild; oobe; oobe = oobe.nextElementSibling) {
                    if (oobe.localName !== 'OOBE') continue;
                    for (let el = oobe.firstElementChild; el; el = el.nextElementSibling) {
                        result[el.localName] = el.textContent.trim();
                    }
                }
            }
        }

        /* Also read ComputerName from specialize pass (read-only display) */
        for (let settings = doc.documentElement.firstElementChild; settings; settings = settings.nextElementSibling) {
            if (settings.localName !== 'settings' || settings.getAttribute('pass') !== 'specialize') continue;
            for (let comp = settings.firstElementChild; comp; comp = comp.nextElementSibling) {
                if (comp.localName !== 'component' || comp.getAttribute('name') !== 'Microsoft-Windows-Shell-Setup') continue;
                for (let el = comp.firstElementChild; el; el = el.nextElementSibling) {
                    if (el.localName === 'ComputerName') {
                        result._computerName = el.textContent.trim();
                    }
                }
            }
        }

        /* Read locale settings from oobeSystem → International-Core (read-only display) */
        for (let settings = doc.documentElement.firstElementChild; settings; settings = settings.nextElementSibling) {
            if (settings.localName !== 'settings' || settings.getAttribute('pass') !== 'oobeSystem') continue;
            for (let comp = settings.firstElementChild; comp; comp = comp.nextElementSibling) {
                if (comp.localName !== 'component' || comp.getAttribute('name') !== 'Microsoft-Windows-International-Core') continue;
                for (let el = comp.firstElementChild; el; el = el.nextElementSibling) {
                    result['_locale_' + el.localName] = el.textContent.trim();
                }
            }
        }
    } catch (_) { /* Ignore parse errors — fall back to defaults */ }
    return result;
}

/**
 * Update the unattend XML string with values from the visual builder form.
 * Only touches the OOBE element under oobeSystem → Shell-Setup.
 */
function updateXmlFromVisualBuilder(xml, values) {
    if (!xml || !xml.trim()) xml = defaultUnattendXml || '';
    if (!xml) return xml;

    var parser = new DOMParser();
    var doc = parser.parseFromString(xml, 'application/xml');
    if (doc.querySelector('parsererror')) return xml; /* Don't corrupt invalid XML */

    var NS = 'urn:schemas-microsoft-com:unattend';

    function ensureEl(parent, localName, attrs) {
        for (var c = parent.firstElementChild; c; c = c.nextElementSibling) {
            if (c.localName !== localName) continue;
            var match = true;
            if (attrs) {
                for (var k in attrs) {
                    if (c.getAttribute(k) !== attrs[k]) { match = false; break; }
                }
            }
            if (match) return c;
        }
        var el = doc.createElementNS(NS, localName);
        if (attrs) { for (var k in attrs) el.setAttribute(k, attrs[k]); }
        parent.appendChild(el);
        return el;
    }

    /* Find or create oobeSystem → Shell-Setup → OOBE */
    var oobePass = ensureEl(doc.documentElement, 'settings', { pass: 'oobeSystem' });
    var shellComp = ensureEl(oobePass, 'component', { name: 'Microsoft-Windows-Shell-Setup' });
    if (!shellComp.getAttribute('processorArchitecture')) {
        shellComp.setAttribute('processorArchitecture', 'amd64');
        shellComp.setAttribute('publicKeyToken', '31bf3856ad364e35');
        shellComp.setAttribute('language', 'neutral');
        shellComp.setAttribute('versionScope', 'nonSxS');
        shellComp.setAttributeNS('http://www.w3.org/2000/xmlns/', 'xmlns:wcm', 'http://schemas.microsoft.com/WMIConfig/2002/State');
    }
    var oobeEl = ensureEl(shellComp, 'OOBE');

    /* Update each OOBE field */
    OOBE_VISUAL_FIELDS.forEach(function (f) {
        var val = values[f.key];
        if (val === undefined || val === null) val = f.defaultVal;
        /* Ensure value is a string for XML */
        var strVal = String(val);
        var existing = null;
        for (var c = oobeEl.firstElementChild; c; c = c.nextElementSibling) {
            if (c.localName === f.key) { existing = c; break; }
        }
        if (existing) {
            existing.textContent = strVal;
        } else {
            var node = doc.createElementNS(NS, f.key);
            node.textContent = strVal;
            oobeEl.appendChild(node);
        }
    });

    var serializer = new XMLSerializer();
    return formatXml(serializer.serializeToString(doc));
}

/**
 * Render the visual builder form inside the container and wire up events.
 */
function renderVisualUnattendForm(builderEl, textarea, step) {
    var xml = textarea.value || defaultUnattendXml || '';
    var parsed = parseOobeSettingsFromXml(xml);

    var html = '';

    /* ── oobeSystem pass: OOBE Settings section ──────────────────────── */
    html += '<div class="vub-section">';
    html += '<div class="vub-pass-header"><span class="vub-pass-badge">oobeSystem</span> OOBE Settings</div>';
    html += '<div class="vub-pass-hint">Microsoft-Windows-Shell-Setup → OOBE</div>';

    /* Template selector */
    html += '<div class="vub-template-bar">';
    html += '<label class="vub-template-label">Template</label>';
    html += '<select class="vub-template-select" data-vub-template>';
    html += '<option value="">— Select a preset —</option>';
    UNATTEND_TEMPLATES.forEach(function (t) {
        html += '<option value="' + escapeHtml(t.id) + '">' + escapeHtml(t.label) + ' — ' + escapeHtml(t.description) + '</option>';
    });
    html += '</select>';
    html += '</div>';

    OOBE_VISUAL_FIELDS.forEach(function (f) {
        var rawVal = parsed[f.key];
        var val;
        if (f.kind === 'checkbox') {
            val = rawVal !== undefined ? rawVal === 'true' : f.defaultVal;
        } else {
            val = rawVal !== undefined ? rawVal : String(f.defaultVal);
        }

        html += '<div class="vub-field">';
        if (f.kind === 'checkbox') {
            html += '<label class="vub-cb-label">' +
                '<input type="checkbox" data-vub="' + f.key + '"' + (val ? ' checked' : '') + '> ' +
                escapeHtml(f.label) + '</label>';
        } else if (f.kind === 'select') {
            html += '<label class="vub-label">' + escapeHtml(f.label) + '</label>';
            html += '<select data-vub="' + f.key + '">';
            f.options.forEach(function (o) {
                html += '<option value="' + escapeHtml(o.value) + '"' + (val === o.value ? ' selected' : '') + '>' + escapeHtml(o.label) + '</option>';
            });
            html += '</select>';
        }
        if (f.hint) html += '<div class="vub-hint">' + escapeHtml(f.hint) + '</div>';
        html += '</div>';
    });
    html += '</div>';

    /* ── Read-only managed settings ──────────────────────────────────── */
    var managedItems = [];
    if (parsed._computerName) {
        managedItems.push({ pass: 'specialize', label: 'Computer Name', value: parsed._computerName, source: 'SetComputerName step' });
    }
    var localeKeys = ['InputLocale', 'SystemLocale', 'UserLocale', 'UILanguage'];
    localeKeys.forEach(function (k) {
        var v = parsed['_locale_' + k];
        if (v) managedItems.push({ pass: 'oobeSystem', label: k.replace(/([A-Z])/g, ' $1').trim(), value: v, source: 'SetRegionalSettings step' });
    });

    if (managedItems.length) {
        html += '<div class="vub-section vub-managed">';
        html += '<div class="vub-pass-header"><span class="vub-pass-badge vub-badge-managed">&#128274;</span> Managed by Other Steps</div>';
        html += '<div class="vub-pass-hint">These values are synced automatically and cannot be edited here</div>';
        managedItems.forEach(function (item) {
            html += '<div class="vub-managed-row">' +
                '<span class="vub-managed-pass">' + escapeHtml(item.pass) + '</span>' +
                '<span class="vub-managed-label">' + escapeHtml(item.label) + '</span>' +
                '<span class="vub-managed-value">' + escapeHtml(item.value) + '</span>' +
                '<span class="vub-managed-source">' + escapeHtml(item.source) + '</span>' +
                '</div>';
        });
        html += '</div>';
    }

    builderEl.innerHTML = html;

    /* Wire up change events — update XML on each change */
    builderEl.querySelectorAll('[data-vub]').forEach(function (input) {
        var event = (input.type === 'checkbox' || input.tagName === 'SELECT') ? 'change' : 'input';
        input.addEventListener(event, function () {
            var newValues = {};
            builderEl.querySelectorAll('[data-vub]').forEach(function (inp) {
                var key = inp.getAttribute('data-vub');
                newValues[key] = inp.type === 'checkbox' ? String(inp.checked) : inp.value;
            });
            var updated = updateXmlFromVisualBuilder(textarea.value, newValues);
            textarea.value = updated;
            textarea.dispatchEvent(new Event('input')); /* Trigger line numbers + data save */
        });
    });

    /* Wire up template selector */
    var tplSelect = builderEl.querySelector('[data-vub-template]');
    if (tplSelect) {
        tplSelect.addEventListener('change', function () {
            var tplId = tplSelect.value;
            if (!tplId) return;
            var tpl = UNATTEND_TEMPLATES.find(function (t) { return t.id === tplId; });
            if (!tpl) return;
            /* Apply template values to the form inputs */
            OOBE_VISUAL_FIELDS.forEach(function (f) {
                var inp = builderEl.querySelector('[data-vub="' + f.key + '"]');
                if (!inp) return;
                var val = tpl.values[f.key];
                if (inp.type === 'checkbox') {
                    inp.checked = val === 'true';
                } else {
                    inp.value = val || '';
                }
            });
            /* Update XML from the new values */
            var updated = updateXmlFromVisualBuilder(textarea.value, tpl.values);
            textarea.value = updated;
            textarea.dispatchEvent(new Event('input'));
            /* Reset template selector back to placeholder */
            tplSelect.value = '';
        });
    }
}

/**
 * Set up the Visual/XML view toggle and render the visual builder.
 */
function setupVisualUnattendBuilder(container, textarea, step) {
    var builderEl = container.querySelector('.visual-unattend-builder');
    var rawEl = container.querySelector('.xml-editor-raw');
    var toggleBtns = container.querySelectorAll('.xml-view-btn');
    if (!builderEl || !rawEl || !toggleBtns.length) return;

    /* Render visual builder form */
    renderVisualUnattendForm(builderEl, textarea, step);

    /* Toggle handler */
    toggleBtns.forEach(function (btn) {
        btn.addEventListener('click', function () {
            var view = btn.getAttribute('data-view');
            toggleBtns.forEach(function (b) { b.classList.remove('active'); });
            btn.classList.add('active');
            if (view === 'visual') {
                rawEl.classList.add('hidden');
                builderEl.classList.remove('hidden');
                /* Re-render visual form from current XML */
                renderVisualUnattendForm(builderEl, textarea, step);
            } else {
                builderEl.classList.add('hidden');
                rawEl.classList.remove('hidden');
            }
        });
    });

    /* When the XML textarea changes externally (e.g. via syncUnattendContent),
       refresh the visual builder if it's visible */
    textarea.addEventListener('vub-refresh', function () {
        if (!builderEl.classList.contains('hidden')) {
            renderVisualUnattendForm(builderEl, textarea, step);
        }
    });
}

/* ── Duplicate step ───────────────────────────────────────────────── */
function duplicateSelectedStep() {
    if (selectedIndex < 0 || !taskSequence.steps[selectedIndex]) return;
    const original = taskSequence.steps[selectedIndex];
    const clone = JSON.parse(JSON.stringify(original));
    clone.id = generateStepId(clone.type);
    clone.name = (clone.name || 'Step') + ' (Copy)';
    const insertAt = selectedIndex + 1;
    taskSequence.steps.splice(insertAt, 0, clone);
    selectedIndex = insertAt;
    markDirty();
    renderStepList();
    selectStep(selectedIndex);
    if (clone.type === 'SetComputerName' || clone.type === 'SetRegionalSettings') {
        syncUnattendContent();
    }
}

document.getElementById('btnDuplicateStep').addEventListener('click', duplicateSelectedStep);

/* ── Step search filter ───────────────────────────────────────────── */
if ($stepSearch) {
    $stepSearch.addEventListener('input', function () {
        renderStepList();
    });
}

/* ── Undo / Redo toolbar buttons ──────────────────────────────────── */
if ($btnUndo) $btnUndo.addEventListener('click', undo);
if ($btnRedo) $btnRedo.addEventListener('click', redo);

/* ── JSON raw view toggle ─────────────────────────────────────────── */
function showJsonRawView() {
    if (selectedIndex < 0 || !taskSequence.steps[selectedIndex]) return;
    jsonRawMode = true;
    $jsonToggle.textContent = '📋 Form View';
    $jsonToggle.title = 'Switch to form view';
    $jsonRawEditor.classList.remove('hidden');
    $paramFields.classList.add('hidden');
    $jsonRawTextarea.value = JSON.stringify(taskSequence.steps[selectedIndex], null, 2);
    $jsonRawError.classList.add('hidden');
}

function hideJsonRawView() {
    jsonRawMode = false;
    $jsonToggle.textContent = '{ } JSON';
    $jsonToggle.title = 'Switch to raw JSON view';
    $jsonRawEditor.classList.add('hidden');
    $paramFields.classList.remove('hidden');
}

function applyJsonRawEdits() {
    if (selectedIndex < 0 || !$jsonRawTextarea) return true;
    try {
        const edited = JSON.parse($jsonRawTextarea.value);
        if (!edited || typeof edited !== 'object') throw new Error('Must be a JSON object');
        taskSequence.steps[selectedIndex] = edited;
        $jsonRawError.classList.add('hidden');
        return true;
    } catch (err) {
        $jsonRawError.textContent = '\u26A0 ' + err.message;
        $jsonRawError.classList.remove('hidden');
        return false;
    }
}

if ($jsonToggle) {
    $jsonToggle.addEventListener('click', function () {
        if (jsonRawMode) {
            /* Switching back to form view — apply edits first */
            if (!applyJsonRawEdits()) return;
            markDirty();
            hideJsonRawView();
            selectStep(selectedIndex);
            renderStepList();
        } else {
            showJsonRawView();
        }
    });
}

/* ── Keyboard shortcuts ───────────────────────────────────────────── */
document.addEventListener('keydown', (e) => {
    /* Undo / Redo work even inside inputs */
    if ((e.ctrlKey || e.metaKey) && !e.shiftKey && e.key === 'z') {
        e.preventDefault();
        undo();
        return;
    }
    if ((e.ctrlKey || e.metaKey) && (e.key === 'y' || (e.shiftKey && e.key === 'Z'))) {
        e.preventDefault();
        redo();
        return;
    }

    /* Skip remaining shortcuts when inside an editable field */
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT' || e.target.isContentEditable) {
        /* Allow Escape to blur search and refocus step list */
        if (e.key === 'Escape' && e.target === $stepSearch) {
            e.target.blur();
        }
        return;
    }
    /* Arrow Up — navigate to previous step */
    if (e.key === 'ArrowUp' && taskSequence.steps.length > 0) {
        e.preventDefault();
        const upIdx = selectedIndex <= 0 ? 0 : selectedIndex - 1;
        selectStep(upIdx);
        scrollStepIntoView(upIdx);
        return;
    }
    /* Arrow Down — navigate to next step */
    if (e.key === 'ArrowDown' && taskSequence.steps.length > 0) {
        e.preventDefault();
        const maxIdx = taskSequence.steps.length - 1;
        const downIdx = selectedIndex < 0 ? 0 : (selectedIndex >= maxIdx ? maxIdx : selectedIndex + 1);
        selectStep(downIdx);
        scrollStepIntoView(downIdx);
        return;
    }
    /* Arrow Left — collapse current step's group */
    if (e.key === 'ArrowLeft' && selectedIndex >= 0) {
        const group = taskSequence.steps[selectedIndex] && taskSequence.steps[selectedIndex].group;
        if (group && !collapsedGroups.has(group)) {
            e.preventDefault();
            collapsedGroups.add(group);
            saveCollapsedGroups();
            renderStepList();
            return;
        }
    }
    /* Arrow Right — expand current step's group */
    if (e.key === 'ArrowRight' && selectedIndex >= 0) {
        const group = taskSequence.steps[selectedIndex] && taskSequence.steps[selectedIndex].group;
        if (group && collapsedGroups.has(group)) {
            e.preventDefault();
            collapsedGroups.delete(group);
            saveCollapsedGroups();
            renderStepList();
            return;
        }
    }
    /* Escape — clear search filter */
    if (e.key === 'Escape') {
        if ($stepSearch && $stepSearch.value) {
            $stepSearch.value = '';
            renderStepList();
        }
        return;
    }
    /* Ctrl+F or / — focus search input */
    if (e.key === '/' || ((e.ctrlKey || e.metaKey) && e.key === 'f')) {
        if ($stepSearch) {
            e.preventDefault();
            $stepSearch.focus();
            $stepSearch.select();
        }
        return;
    }
    if (e.key === 'Delete' && selectedIndex >= 0) {
        document.getElementById('btnRemoveStep').click();
    }
    /* Ctrl+D — duplicate step */
    if ((e.ctrlKey || e.metaKey) && e.key === 'd') {
        e.preventDefault();
        duplicateSelectedStep();
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
            ta.dispatchEvent(new Event('vub-refresh'));  /* Update visual builder */
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
    /* Check for auto-saved draft */
    var draftJson = null;
    try { draftJson = localStorage.getItem(DRAFT_KEY); } catch (_) {}
    if (draftJson) {
        try {
            var draftData = JSON.parse(draftJson);
            if (draftData && draftData.steps && Array.isArray(draftData.steps)) {
                if (confirm('An unsaved draft was found. Would you like to restore it?')) {
                    taskSequence = draftData;
                    $tsName.textContent = taskSequence.name || 'Untitled';
                    updateBreadcrumb(taskSequence.name || 'Untitled');
                    selectedIndex = taskSequence.steps.length > 0 ? 0 : -1;
                    dirty = true;
                    updateDirtyUI();
                    captureSnapshot();
                    renderStepList();
                    selectStep(selectedIndex);
                    fetch('../../../resources/unattend/unattend.xml')
                        .then(function (r) { if (!r.ok) throw new Error(r.statusText); return r.text(); })
                        .then(function (xml) {
                            defaultUnattendXml = xml;
                            if (defaultUnattendXml) typeMap.CustomizeOOBE.defaults.unattendContent = defaultUnattendXml;
                            populateDefaultUnattendContent(taskSequence.steps);
                            syncUnattendContent();
                        }).catch(function () {});
                    return;
                } else {
                    localStorage.removeItem(DRAFT_KEY);
                }
            }
        } catch (_) {
            localStorage.removeItem(DRAFT_KEY);
        }
    }

    /* Determine source from URL parameters */
    var params = new URLSearchParams(window.location.search);
    var tsParam = params.get('ts');
    var isNew = params.get('new');
    var SESSION_PREFIX = 'session:';

    if (isNew) {
        /* Start with an empty task sequence */
        taskSequence = { name: 'New Task Sequence', version: '1.0', description: '', steps: [] };
        currentFilePath = null;
        $tsName.textContent = taskSequence.name;
        updateBreadcrumb(taskSequence.name);
        selectedIndex = -1;
        renderStepList();
        selectStep(-1);
        /* Still fetch the default unattend.xml for the Reset button */
        fetch('../../../resources/unattend/unattend.xml')
            .then(function (r) { if (!r.ok) throw new Error(r.statusText); return r.text(); })
            .then(function (xml) {
                defaultUnattendXml = xml;
                if (defaultUnattendXml) {
                    typeMap.CustomizeOOBE.defaults.unattendContent = defaultUnattendXml;
                }
            }).catch(function () { /* Ignore */ });
        return;
    }

    if (tsParam && tsParam.indexOf(SESSION_PREFIX) === 0) {
        /* Load from sessionStorage (imported / duplicated from dashboard) */
        var sessionKey = tsParam.slice(SESSION_PREFIX.length);
        var stored = sessionStorage.getItem(sessionKey);
        if (stored) {
            try {
                var data = JSON.parse(stored);
                if (data.steps && Array.isArray(data.steps)) {
                    currentFilePath = null;
                    /* Also fetch the default unattend.xml */
                    fetch('../../../resources/unattend/unattend.xml')
                        .then(function (r) { if (!r.ok) throw new Error(r.statusText); return r.text(); })
                        .catch(function () { return ''; })
                        .then(function (xml) {
                            defaultUnattendXml = xml;
                            if (defaultUnattendXml) {
                                typeMap.CustomizeOOBE.defaults.unattendContent = defaultUnattendXml;
                            }
                            taskSequence = data;
                            populateDefaultUnattendContent(taskSequence.steps);
                            syncUnattendContent();
                            $tsName.textContent = taskSequence.name || 'Untitled';
                            updateBreadcrumb(taskSequence.name || 'Untitled');
                            selectedIndex = taskSequence.steps.length > 0 ? 0 : -1;
                            renderStepList();
                            selectStep(selectedIndex);
                            captureSnapshot();
                        });
                    return;
                }
            } catch (_) { /* Fall through to default load */ }
        }
    }

    /* Default: load from resources/task-sequence/default.json */
    Promise.all([
        fetch('../../../resources/task-sequence/default.json')
            .then(r => { if (!r.ok) throw new Error(r.statusText); return r.json(); }),
        fetch('../../../resources/unattend/unattend.xml')
            .then(r => { if (!r.ok) throw new Error(r.statusText); return r.text(); })
            .catch(() => '')
    ]).then(([data, xml]) => {
        defaultUnattendXml = xml;

        /* Use the repo XML as the default for the CustomizeOOBE type */
        if (defaultUnattendXml) {
            typeMap.CustomizeOOBE.defaults.unattendContent = defaultUnattendXml;
        }

        taskSequence = data;
        currentFilePath = 'resources/task-sequence/default.json';

        /* Fill empty unattendContent from the repo file */
        populateDefaultUnattendContent(taskSequence.steps);

        /* Sync step values (SetComputerName, SetRegionalSettings) into unattend.xml */
        syncUnattendContent();

        $tsName.textContent = taskSequence.name || 'Untitled';
        updateBreadcrumb(taskSequence.name || 'Untitled');
        selectedIndex = taskSequence.steps.length > 0 ? 0 : -1;
        renderStepList();
        selectStep(selectedIndex);
        captureSnapshot();
    }).catch(() => {
        /* No default file available — start empty */
        renderStepList();
    });
}

/** Update the breadcrumb with the current task sequence name. */
function updateBreadcrumb(name) {
    var el = document.getElementById('breadcrumbName');
    if (el) el.textContent = name || 'Editor';
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
        loginOverlay.classList.add('hidden');
        toolbar.classList.remove('hidden');
        mainLayout.classList.remove('hidden');
        if (account && account.name) {
            userName.textContent = account.name;
            userName.classList.remove('hidden');
            btnLogout.classList.remove('hidden');
        }
        loadDefault();
    }

    /** Show the login UI (hide loading text, show button). */
    function showLoginUI() {
        loginLoading.classList.add('hidden');
        btnLogin.classList.remove('hidden');
    }

    /* Fetch auth config from the repository. */
    fetch('../../../config/auth.json')
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
                loginLoading.classList.add('hidden');
                btnLogin.classList.add('hidden');
                loginError.textContent = 'Authentication library failed to load. Check your network, ad-blocker, or corporate network restrictions.';
                loginError.classList.remove('hidden');
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

            /* MSAL v4+ requires explicit initialisation before any API call. */
            msalApp.initialize().then(() => {
                return msalApp.handleRedirectPromise();
            }).then(response => {
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
                loginError.classList.add('hidden');
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
