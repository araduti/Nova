import { describe, expect, it } from 'vitest';
import { toBase64, formatXml, validateStep, validateTaskSequence } from '../js/utils.js';

/* ── toBase64 ────────────────────────────────────────────────────── */

describe('toBase64', () => {
  it('encodes an ASCII string', () => {
    expect(toBase64('hello')).toBe(btoa('hello'));
  });

  it('encodes an empty string', () => {
    expect(toBase64('')).toBe('');
  });

  it('handles UTF-8 multi-byte characters', () => {
    // btoa cannot handle raw multi-byte, but toBase64 uses TextEncoder
    const result = toBase64('café');
    // Decode back to verify round-trip
    const decoded = new TextDecoder().decode(
      Uint8Array.from(atob(result), c => c.charCodeAt(0)),
    );
    expect(decoded).toBe('café');
  });
});

/* ── formatXml ───────────────────────────────────────────────────── */

describe('formatXml', () => {
  it('indents nested elements with 2 spaces', () => {
    const input = '<root><child>text</child></root>';
    const lines = formatXml(input).split('\n');
    expect(lines[0]).toBe('<root>');
    expect(lines[1]).toBe('  <child>text</child>');
    expect(lines[2]).toBe('</root>');
  });

  it('handles self-closing tags without extra indent', () => {
    const input = '<root><item /><item /></root>';
    const lines = formatXml(input).split('\n');
    expect(lines[0]).toBe('<root>');
    expect(lines[1]).toBe('  <item />');
    expect(lines[2]).toBe('  <item />');
    expect(lines[3]).toBe('</root>');
  });

  it('preserves XML declaration', () => {
    const input = '<?xml version="1.0"?><root />';
    const output = formatXml(input);
    expect(output).toContain('<?xml version="1.0"?>');
  });

  it('returns the original string on empty input', () => {
    expect(formatXml('')).toBe('');
  });
});

/* ── validateStep ────────────────────────────────────────────────── */

describe('validateStep', () => {
  it('returns no warnings for a valid PartitionDisk step', () => {
    const step = { type: 'PartitionDisk', parameters: { diskNumber: 0 } };
    expect(validateStep(step)).toEqual([]);
  });

  it('warns when PartitionDisk has negative disk number', () => {
    const step = { type: 'PartitionDisk', parameters: { diskNumber: -1 } };
    expect(validateStep(step)).toContain('Disk number must be >= 0');
  });

  it('warns when DownloadImage edition is empty', () => {
    const step = { type: 'DownloadImage', parameters: { edition: '' } };
    expect(validateStep(step)).toContain('Edition is empty');
  });

  it('warns when ApplyImage edition is empty', () => {
    const step = { type: 'ApplyImage', parameters: {} };
    expect(validateStep(step)).toContain('Edition is empty');
  });

  it('warns when InjectDrivers has no driverPath', () => {
    const step = { type: 'InjectDrivers', parameters: {} };
    expect(validateStep(step)).toContain('Driver path is empty');
  });

  it('warns when ApplyAutopilot has neither URL nor path', () => {
    const step = { type: 'ApplyAutopilot', parameters: {} };
    expect(validateStep(step)).toContain('Either JSON URL or JSON path must be provided');
  });

  it('passes when ApplyAutopilot has jsonUrl', () => {
    const step = { type: 'ApplyAutopilot', parameters: { jsonUrl: 'https://example.com/ap.json' } };
    expect(validateStep(step)).toEqual([]);
  });

  it('warns when StageCCMSetup has no URL', () => {
    const step = { type: 'StageCCMSetup', parameters: {} };
    expect(validateStep(step)).toContain('CCMSetup URL is empty');
  });

  it('warns when SetComputerName maxLength exceeds 15', () => {
    const step = { type: 'SetComputerName', parameters: { maxLength: 20 } };
    expect(validateStep(step)).toContain('Max length exceeds NetBIOS limit of 15');
  });

  it('warns when RunPostScripts has no URLs', () => {
    const step = { type: 'RunPostScripts', parameters: { scriptUrls: [] } };
    expect(validateStep(step)).toContain('No script URLs configured');
  });

  it('warns on empty condition variable name', () => {
    const step = { type: 'PartitionDisk', parameters: { diskNumber: 0 }, condition: { type: 'variable', variable: '' } };
    expect(validateStep(step)).toContain('Condition: variable name is empty');
  });

  it('warns on empty WMI query condition', () => {
    const step = { type: 'PartitionDisk', parameters: { diskNumber: 0 }, condition: { type: 'wmiQuery', query: '' } };
    expect(validateStep(step)).toContain('Condition: WMI query is empty');
  });

  it('warns on empty registry path condition', () => {
    const step = { type: 'PartitionDisk', parameters: { diskNumber: 0 }, condition: { type: 'registry', registryPath: '' } };
    expect(validateStep(step)).toContain('Condition: registry path is empty');
  });

  it('returns no warnings for unknown step type', () => {
    const step = { type: 'CustomStep', parameters: {} };
    expect(validateStep(step)).toEqual([]);
  });
});

/* ── validateTaskSequence ────────────────────────────────────────── */

describe('validateTaskSequence', () => {
  it('warns when task sequence has no steps', () => {
    const ts = { steps: [] };
    const results = validateTaskSequence(ts);
    expect(results).toHaveLength(1);
    expect(results[0]).toEqual({ level: 'warning', message: 'Task sequence has no steps' });
  });

  it('returns pass for a valid minimal sequence', () => {
    const ts = {
      steps: [
        { type: 'PartitionDisk', name: 'Partition', id: 'p1', parameters: { diskNumber: 0 } },
        { type: 'ApplyImage', name: 'Apply', id: 'a1', parameters: { edition: 'Pro' } },
        { type: 'SetBootloader', name: 'Boot', id: 'b1', parameters: {} },
      ],
    };
    const results = validateTaskSequence(ts);
    expect(results).toHaveLength(1);
    expect(results[0].level).toBe('pass');
  });

  it('errors when ApplyImage exists but PartitionDisk does not', () => {
    const ts = {
      steps: [
        { type: 'ApplyImage', name: 'Apply', id: 'a1', parameters: { edition: 'Pro' } },
      ],
    };
    const results = validateTaskSequence(ts);
    expect(results.some(r => r.level === 'error' && r.message.includes('no PartitionDisk'))).toBe(true);
  });

  it('errors when PartitionDisk comes after ApplyImage', () => {
    const ts = {
      steps: [
        { type: 'ApplyImage', name: 'Apply', id: 'a1', parameters: { edition: 'Pro' } },
        { type: 'PartitionDisk', name: 'Partition', id: 'p1', parameters: { diskNumber: 0 } },
      ],
    };
    const results = validateTaskSequence(ts);
    expect(results.some(r => r.level === 'error' && r.message.includes('should come before'))).toBe(true);
  });

  it('warns when DownloadImage comes after ApplyImage', () => {
    const ts = {
      steps: [
        { type: 'PartitionDisk', name: 'Partition', id: 'p1', parameters: { diskNumber: 0 } },
        { type: 'ApplyImage', name: 'Apply', id: 'a1', parameters: { edition: 'Pro' } },
        { type: 'DownloadImage', name: 'Download', id: 'd1', parameters: { edition: 'Pro' } },
      ],
    };
    const results = validateTaskSequence(ts);
    expect(results.some(r => r.level === 'warning' && r.message.includes('DownloadImage'))).toBe(true);
  });

  it('detects duplicate step IDs', () => {
    const ts = {
      steps: [
        { type: 'PartitionDisk', name: 'Part1', id: 'dup', parameters: { diskNumber: 0 } },
        { type: 'ApplyImage', name: 'Apply', id: 'dup', parameters: { edition: 'Pro' } },
      ],
    };
    const results = validateTaskSequence(ts);
    expect(results.some(r => r.level === 'error' && r.message.includes('Duplicate step ID'))).toBe(true);
  });

  it('warns on steps with empty names', () => {
    const ts = {
      steps: [
        { type: 'PartitionDisk', name: '', id: 'p1', parameters: { diskNumber: 0 } },
      ],
    };
    const results = validateTaskSequence(ts);
    expect(results.some(r => r.level === 'warning' && r.message.includes('empty name'))).toBe(true);
  });

  it('skips disabled steps in per-step validation', () => {
    const ts = {
      steps: [
        { type: 'PartitionDisk', name: 'Part', id: 'p1', enabled: true, parameters: { diskNumber: 0 } },
        { type: 'ApplyImage', name: 'Apply', id: 'a1', enabled: false, parameters: {} },
      ],
    };
    const results = validateTaskSequence(ts);
    // ApplyImage has empty edition but is disabled — no per-step warning for it
    expect(results.some(r => r.message.includes('Edition is empty'))).toBe(false);
  });

  it('handles undefined steps array', () => {
    const ts = {};
    const results = validateTaskSequence(ts);
    expect(results).toHaveLength(1);
    expect(results[0].level).toBe('warning');
  });

  it('warns when SetBootloader has no ApplyImage', () => {
    const ts = {
      steps: [
        { type: 'SetBootloader', name: 'Boot', id: 'b1', parameters: {} },
      ],
    };
    const results = validateTaskSequence(ts);
    expect(results.some(r => r.level === 'warning' && r.message.includes('SetBootloader is enabled but no ApplyImage'))).toBe(true);
  });
});
