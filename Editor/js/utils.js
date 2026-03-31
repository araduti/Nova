/**
 * Pure utility functions shared by the Nova Task Sequence Editor.
 *
 * These are extracted from Editor/js/app.js so they can be imported in
 * Vitest tests AND consumed by the browser build (via a <script> tag
 * that defines the same functions on the global scope).
 *
 * Convention: this file must stay free of DOM / browser-only globals
 * except where the caller is expected to polyfill them (e.g. DOMParser).
 */

/* ── Encoding ────────────────────────────────────────────────────── */

/**
 * Encode a string as Base64 (UTF-8 safe).
 * @param {string} str
 * @returns {string}
 */
export function toBase64(str) {
  const bytes = new TextEncoder().encode(str);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/* ── XML helpers ─────────────────────────────────────────────────── */

/**
 * Pretty-print XML with consistent 2-space indentation.
 * @param {string} xml
 * @returns {string}
 */
export function formatXml(xml) {
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

/* ── Step validation ─────────────────────────────────────────────── */

/**
 * Validate a single task-sequence step's parameters.
 * Returns an array of warning strings (empty = valid).
 * @param {{ type: string, parameters?: Record<string, unknown>, condition?: { type?: string, variable?: string, query?: string, registryPath?: string } }} step
 * @returns {string[]}
 */
export function validateStep(step) {
  const warnings = [];
  const p = step.parameters || {};
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
  const cond = step.condition;
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

/**
 * Run pre-flight checks on a full task sequence object.
 * Returns an array of { level: 'error'|'warning'|'pass', message: string }.
 * @param {{ steps?: Array<{ type: string, enabled?: boolean, id?: string, name?: string, parameters?: Record<string, unknown>, condition?: object }> }} taskSequence
 * @returns {Array<{ level: string, message: string }>}
 */
export function validateTaskSequence(taskSequence) {
  const results = [];
  const steps = taskSequence.steps || [];

  if (steps.length === 0) {
    results.push({ level: 'warning', message: 'Task sequence has no steps' });
    return results;
  }

  /* Helper: find the first enabled step index of a given type */
  function firstEnabled(type) {
    for (let i = 0; i < steps.length; i++) {
      if (steps[i].type === type && steps[i].enabled !== false) return i;
    }
    return -1;
  }

  /* ── Required steps ─────────────────────────────────────────────── */
  const partIdx   = firstEnabled('PartitionDisk');
  const applyIdx  = firstEnabled('ApplyImage');
  const bootIdx   = firstEnabled('SetBootloader');
  const dlIdx     = firstEnabled('DownloadImage');
  const cnIdx     = firstEnabled('SetComputerName');
  const rsIdx     = firstEnabled('SetRegionalSettings');
  const oobeIdx   = firstEnabled('CustomizeOOBE');

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
  const idsSeen = {};
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
      results.push({ level: 'warning', message: 'Step ' + (i + 1) + ' (' + (s.name || s.type) + '): ' + w });
    });
  });

  /* ── Summary pass ───────────────────────────────────────────────── */
  if (results.length === 0) {
    results.push({ level: 'pass', message: 'All checks passed (' + steps.length + ' steps, ' + (steps.length - steps.filter(function (s) { return s.enabled === false; }).length) + ' enabled)' });
  }

  return results;
}
