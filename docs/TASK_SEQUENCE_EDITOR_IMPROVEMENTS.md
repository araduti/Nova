# Task Sequence Editor — Improvement Ideas & Research

This document outlines ideas for improving the Nova Task Sequence Editor to compete with and surpass established tools like MDT (Microsoft Deployment Toolkit), PDT (PowerShell Deployment Toolkit), and SCCM/MECM (Microsoft Endpoint Configuration Manager).

---

## 1. Dashboard / Overview Page

**Status:** ✅ Implemented

Currently the root page immediately redirects into the editor. A proper **Task Sequence Dashboard** should be the first thing users see, providing an overview before they drill into a specific sequence.

### Implemented Features
- **Card-based grid** showing each task sequence with name, description, step count, and enabled/disabled step indicators.
- **Quick actions** — open, duplicate, download, or delete a task sequence from the dashboard.
- **Import / New** buttons to create or upload task sequences without entering the editor first.
- **Recently-opened list** stored in `localStorage` so users can quickly resume editing.
- **Visual status indicators** — step count badges, enabled/disabled ratio.

### Future Enhancements
- **Folder / tag organization** — group task sequences by purpose (e.g., "Autopilot", "Bare Metal", "Refresh").
- **Search and filter** across task sequences by name, step type, or parameter value.
- **Side-by-side comparison** — diff two task sequences to see what changed.
- **Version history** — show recent GitHub commits for each task sequence file and allow restoring older versions.
- **Starred / Favorites** — pin frequently used task sequences to the top.

---

## 2. Editor Design Improvements

### Visual Hierarchy
- **Breadcrumb navigation** ✅ — show `Dashboard > Task Sequence Name` so users always know where they are and can navigate back.
- **Step group visual separators** ✅ — collapsible group headers displayed in the step list when steps have a `group` property. Groups show a chevron, label, and step count.
- **Collapsible step groups** ✅ — click group headers to collapse/expand. Arrow Left/Right keyboard shortcuts. Collapsed state persists in localStorage.

### Step List Enhancements
- **Step validation warning icons** ✅ — show ⚠ warning icons on steps that have validation issues (e.g., missing required parameters, NetBIOS length exceeded).
- **Step search / filter** ✅ — search input in the step list panel filters steps by name or type label as you type. Focus with Ctrl+F or `/`, clear with Escape.
- **Step dependency lines** — visual connectors showing which steps depend on others (e.g., ApplyImage depends on DownloadImage).
- **Thumbnail previews** ✅ — hover over a step to see a multi-line tooltip summarising its key parameters (description, parameter values, condition, enabled state) without selecting it.
- **Multi-select** ✅ — select multiple steps via Ctrl+Click (toggle) and Shift+Click (range) for bulk delete operations. Primary selection shown with accent highlight, secondary selections with subtle highlight.
- **Copy/paste steps** ✅ — duplicate a step within the same sequence (Ctrl+D or toolbar button).
- **Step templates** ✅ — save commonly-used step configurations as reusable templates. Built-in presets (Serial Number Naming, Standard GPT Partition, English/French Regional, Autopilot Full Skip) plus user-saved templates stored in localStorage. Templates tab in the Add Step dialog with inline type badges and delete buttons for user templates. Save selected step as a template via the 🔖 toolbar button.

### Properties Panel
- **Tabbed layout** — split parameters into tabs: General, Advanced, Conditions.
- **Inline validation** ✅ — real-time validation warnings shown per step (e.g., computer name length, missing required parameters). Warnings appear in both the step list and the properties panel.
- **Help tooltips** ✅ — "? Docs" link in the Parameters header opens the relevant Microsoft Learn documentation page for the selected step type. Covers all 13 step types with direct links to partition, DISM, Autopilot, unattend, and scripting docs.
- **Undo/Redo** ✅ — Ctrl+Z / Ctrl+Y for step changes with a 50-level undo stack and toolbar buttons.
- **JSON raw view toggle** ✅ — switch between the form UI and raw JSON editing for power users.

---

## 3. Integration Improvements (Editor ↔ Bootstrap ↔ Engine)

### Task Sequence Validation

**Status:** ✅ Implemented

- **Pre-flight validation** ✅ — toolbar "Validate" button runs a set of checks:
  - Are required steps present (e.g., PartitionDisk before ApplyImage)?
  - Are step dependencies satisfied (e.g., DownloadImage before ApplyImage)?
  - Are parameter values valid (e.g., disk number exists, URL is reachable)?
  - Is the step order logical?
  - Duplicate step IDs and empty step names detected.
- **Warning vs. Error** ✅ — distinguish between warnings (non-blocking) and errors (must fix before deploy).
- **Validation report** ✅ — modal dialog showing color-coded results with error/warning/pass indicators.

### Bootstrap Integration
- **Config modal preview** — show a live preview of what the Bootstrap config menu will look like based on the current task sequence.
- **Variable reference** — show which task sequence parameters are overridable at deploy time from the config modal.
- **Deployment simulation** — a "dry run" mode that walks through the task sequence without executing, logging what each step would do.

### Engine Integration
- **Step compatibility matrix** — show which steps require WinPE-specific features vs. full Windows.
- **Execution time estimates** — based on historical data or rough estimates, show expected duration per step.
- **Error recovery hints** — for each step, show what happens if it fails and how `continueOnError` affects the flow.

---

## 4. Quality & Error Avoidance

### Input Validation
- **Computer name rules** — enforce NetBIOS constraints (max 15 chars, no special characters except hyphens).
- **Locale validation** — validate BCP-47 locale tags against a known list.
- **URL validation** — check URL format and optionally test reachability.
- **Path validation** — warn if a WinPE path doesn't follow expected patterns (e.g., `X:\`, UNC paths).
- **XML validation** — already implemented; extend to validate specific unattend.xml schema compliance.

### Step Order Intelligence
- **Auto-ordering suggestions** — when a user adds a step in a suboptimal position, suggest the correct placement.
- **Dependency graph** — visual representation of step dependencies (e.g., PartitionDisk → ApplyImage → SetBootloader).
- **Circular dependency detection** — prevent configurations that could cause infinite loops or deadlocks.

### Data Integrity
- **Dirty state tracking** ✅ — unsaved changes indicator (amber dot on Save button, document title prefix), `beforeunload` warning prevents accidental data loss.
- **Auto-save drafts** ✅ — debounced save to `localStorage` on every change, with draft recovery prompt on next load.
- **Conflict detection** — when saving to GitHub, detect if someone else modified the file and offer merge resolution.
- **Schema versioning** — version the JSON schema so older task sequences can be migrated automatically.

---

## 5. Competitive Advantages over MDT/SCCM

### What MDT/SCCM Has That We Should Match
| Feature | MDT | SCCM | Nova Status |
|---------|-----|------|-----------------|
| Task sequence overview | ✅ | ✅ | ✅ Dashboard page |
| Step groups / folders | ✅ | ✅ | ✅ Collapsible groups |
| Conditional logic (if/else) | ✅ | ✅ | ✅ Condition UI + engine |
| Variable substitution | ✅ | ✅ | 🔲 Partial (config modal) |
| Error handling per step | ✅ | ✅ | ✅ continueOnError |
| Restart / retry logic | ❌ | ✅ | 🔲 Future |
| Progress reporting | ✅ | ✅ | ✅ Bootstrap UI |
| Logging / diagnostics | ✅ | ✅ | 🔲 Partial |
| Multi-sequence management | ✅ | ✅ | ✅ Dashboard page |
| Import / Export | ✅ | ✅ | ✅ JSON download/upload |

### Where Nova Can Excel
- **Zero infrastructure** — no server, no database, no Active Directory required.
- **Cloud-native** — GitHub as the source of truth, OAuth for auth, CDN for images.
- **Modern web UI** — responsive, dark theme, works on any device with a browser.
- **Real-time collaboration** — future: WebSocket-based multi-user editing.
- **API-first** — task sequences are JSON, making them easy to generate, validate, and version with CI/CD.
- **Open source** — community contributions, transparency, no licensing costs.

---

## 6. Future Feature Ideas

### Conditional Logic

**Status:** ✅ Implemented

- **Step conditions** — each step has an optional `condition` object that is evaluated at runtime. If the condition is not met, the step is skipped.
- **Variable conditions** — check environment or task sequence variables with operators: equals, notEquals, contains, startsWith, exists, notExists.
- **WMI queries** — query hardware properties at runtime (e.g., `SELECT * FROM Win32_ComputerSystem WHERE Model LIKE '%Virtual%'`).
- **Registry checks** — check if a registry key/value exists or matches an expected value.
- **Editor UI** — condition section in the properties panel with type picker, dynamic fields, and validation. Steps with conditions show a ⚡ indicator in the step list.
- **Engine support** — `Test-StepCondition` function evaluates conditions before each step runs.

### Step Groups

**Status:** ✅ Implemented

- **Logical grouping** — group related steps (e.g., "Configuration", "Disk & Image", "Drivers", "Provisioning", "Finalization") via an optional `group` property on each step.
- **Enable/disable groups** — ~~toggle an entire group with one click~~ (future: group-level toggle).
- **Collapsible groups** — click the group header to collapse/expand all steps in that group. Collapsed state persists in localStorage. Keyboard shortcuts: Arrow Left to collapse, Arrow Right to expand.
- **Group assignment** — editable "Group" field in the properties panel with autocomplete suggestions from existing group names. New steps inherit the group of the selected step or use a default based on step type.
- **Drag to group** — drag a step onto a group header to move it into that group.

### Deployment Profiles
- **Named profiles** — save combinations of task sequence + config overrides as deployment profiles.
- **Quick deploy** — one-click deployment with a pre-configured profile.
- **Profile inheritance** — base profile + overrides for different departments or locations.

### Monitoring & Reporting
- **Deployment dashboard** — real-time status of active deployments.
- **Historical reports** — success/failure rates, average deployment time, common errors.
- **Alerting** — email/Teams/Slack notifications on deployment completion or failure.

### Advanced Unattend.xml Management

**Status:** ✅ Mostly Implemented

- **Visual unattend builder** ✅ — form-based editor for OOBE settings (HideEULAPage, HideOEMRegistrationScreen, HideOnlineAccountScreens, HideWirelessSetupInOOBE, ProtectYourPC, SkipMachineOOBE, SkipUserOOBE) with Visual/XML toggle and two-way sync.
- **Pass-aware editing** ✅ — visual builder shows pass badges (oobeSystem, specialize) and component paths. Managed settings from other steps displayed read-only.
- **Template library** ✅ — pre-built unattend templates for common deployment scenarios (Default, Autopilot, Enterprise, Kiosk, Minimal) with one-click application via dropdown selector in the visual builder.
- **Schema validation** — validate against the official Microsoft unattend schema.

---

## 7. Technical Debt & Architecture

### Code Quality
- **TypeScript migration** — add type safety to the editor JavaScript.
- **Component architecture** — split the monolithic `app.js` into modules (StepList, PropertiesPanel, XmlEditor, etc.).
- **Unit tests** — add tests for XML manipulation, validation, and state management.
- **E2E tests** — Playwright/Cypress tests for the editor UI.

### Performance
- **Virtual scrolling** — for task sequences with many steps, only render visible items.
- **Lazy loading** — load step type definitions on demand instead of all at once.
- **Service Worker** — cache the editor for offline use in WinPE environments.

### Accessibility
- **ARIA labels** — ensure all interactive elements have proper ARIA attributes.
- **Keyboard navigation** ✅ — Arrow Up/Down to navigate step list, Ctrl+F or `/` to focus search, Escape to clear search. Full keyboard support for step selection alongside existing Delete and Ctrl+D shortcuts.
- **Screen reader support** — announce state changes (step selected, saved, etc.).
- **High contrast mode** — alternative theme for accessibility.

---

## Implementation Priority

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| ✅ ~~P0~~ | ~~Dashboard overview page~~ | Medium | High |
| ✅ ~~P0~~ | ~~Breadcrumb navigation~~ | Low | High |
| ✅ ~~P1~~ | ~~Step validation warnings~~ | Medium | High |
| ✅ ~~P1~~ | ~~Dirty state / unsaved indicator~~ | Low | Medium |
| ✅ ~~P1~~ | ~~Auto-save drafts to localStorage~~ | Low | Medium |
| ✅ ~~P1~~ | ~~Undo / Redo~~ | Medium | Medium |
| ✅ ~~P1~~ | ~~JSON raw view toggle~~ | Medium | Medium |
| ✅ ~~P1~~ | ~~Duplicate step~~ | Low | Medium |
| ✅ ~~P1~~ | ~~Step search / filter~~ | Low | Medium |
| ✅ ~~P1~~ | ~~Keyboard navigation~~ | Low | Medium |
| ✅ ~~P1~~ | ~~Multi-select~~ | Medium | Medium |
| ✅ ~~P2~~ | ~~Step groups / folders~~ | High | High |
| ✅ ~~P2~~ | ~~Conditional logic (if/else)~~ | High | High |
| ✅ ~~P2~~ | ~~Visual unattend builder~~ | High | Medium |
| 🔵 P3 | Deployment simulation | High | Medium |
| 🔵 P3 | TypeScript migration | High | Medium |
| 🔵 P3 | Real-time collaboration | Very High | Medium |
