# Task Sequence Editor — Improvement Ideas & Research

This document outlines ideas for improving the AmpCloud Task Sequence Editor to compete with and surpass established tools like MDT (Microsoft Deployment Toolkit), PDT (PowerShell Deployment Toolkit), and SCCM/MECM (Microsoft Endpoint Configuration Manager).

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
- **Breadcrumb navigation** — show `Dashboard > Task Sequence Name` so users always know where they are and can navigate back.
- **Step group visual separators** — auto-detect logical groups (Pre-Imaging, Imaging, Post-Imaging) and display section dividers.
- **Collapsible step groups** — allow grouping steps under a heading that can expand/collapse.

### Step List Enhancements
- **Step status icons** — show warning/error icons on steps that have validation issues (e.g., missing required parameters).
- **Step dependency lines** — visual connectors showing which steps depend on others (e.g., ApplyImage depends on DownloadImage).
- **Thumbnail previews** — hover over a step to see a summary tooltip of its key parameters without selecting it.
- **Multi-select** — allow selecting multiple steps for bulk enable/disable, delete, or move operations.
- **Copy/paste steps** — duplicate a step within the same sequence or across sequences.
- **Step templates** — save commonly-used step configurations as reusable templates.

### Properties Panel
- **Tabbed layout** — split parameters into tabs: General, Advanced, Conditions.
- **Inline validation** — real-time feedback on parameter values (e.g., computer name length, URL format, locale validity).
- **Help tooltips** — link to Microsoft documentation for each parameter.
- **Undo/Redo** — support Ctrl+Z / Ctrl+Y for step changes.
- **JSON raw view toggle** — switch between the form UI and raw JSON editing for power users.

---

## 3. Integration Improvements (Editor ↔ Bootstrap ↔ Engine)

### Task Sequence Validation
- **Pre-flight validation** — before saving, run a set of checks:
  - Are required steps present (e.g., PartitionDisk before ApplyImage)?
  - Are step dependencies satisfied (e.g., DownloadImage before ApplyImage)?
  - Are parameter values valid (e.g., disk number exists, URL is reachable)?
  - Is the step order logical?
- **Warning vs. Error** — distinguish between warnings (non-blocking) and errors (must fix before deploy).
- **Validation report** — generate a printable/downloadable validation summary.

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
- **Dirty state tracking** — show an unsaved changes indicator and warn before navigating away.
- **Auto-save drafts** — periodically save the current state to `localStorage` to prevent data loss.
- **Conflict detection** — when saving to GitHub, detect if someone else modified the file and offer merge resolution.
- **Schema versioning** — version the JSON schema so older task sequences can be migrated automatically.

---

## 5. Competitive Advantages over MDT/SCCM

### What MDT/SCCM Has That We Should Match
| Feature | MDT | SCCM | AmpCloud Status |
|---------|-----|------|-----------------|
| Task sequence overview | ✅ | ✅ | ✅ Dashboard page |
| Step groups / folders | ✅ | ✅ | 🔲 Future |
| Conditional logic (if/else) | ✅ | ✅ | 🔲 Future |
| Variable substitution | ✅ | ✅ | 🔲 Partial (config modal) |
| Error handling per step | ✅ | ✅ | ✅ continueOnError |
| Restart / retry logic | ❌ | ✅ | 🔲 Future |
| Progress reporting | ✅ | ✅ | ✅ Bootstrap UI |
| Logging / diagnostics | ✅ | ✅ | 🔲 Partial |
| Multi-sequence management | ✅ | ✅ | ✅ Dashboard page |
| Import / Export | ✅ | ✅ | ✅ JSON download/upload |

### Where AmpCloud Can Excel
- **Zero infrastructure** — no server, no database, no Active Directory required.
- **Cloud-native** — GitHub as the source of truth, OAuth for auth, CDN for images.
- **Modern web UI** — responsive, dark theme, works on any device with a browser.
- **Real-time collaboration** — future: WebSocket-based multi-user editing.
- **API-first** — task sequences are JSON, making them easy to generate, validate, and version with CI/CD.
- **Open source** — community contributions, transparency, no licensing costs.

---

## 6. Future Feature Ideas

### Conditional Logic
- **If/Else steps** — execute steps conditionally based on hardware, OS, or environment variables.
- **WMI queries** — query hardware properties at runtime to make decisions.
- **Registry checks** — check for existing software before installing drivers or agents.

### Step Groups
- **Logical grouping** — group related steps (e.g., "Driver Injection" containing InjectDrivers + InjectOemDrivers).
- **Enable/disable groups** — toggle an entire group with one click.
- **Collapsible groups** — reduce visual clutter in large task sequences.

### Deployment Profiles
- **Named profiles** — save combinations of task sequence + config overrides as deployment profiles.
- **Quick deploy** — one-click deployment with a pre-configured profile.
- **Profile inheritance** — base profile + overrides for different departments or locations.

### Monitoring & Reporting
- **Deployment dashboard** — real-time status of active deployments.
- **Historical reports** — success/failure rates, average deployment time, common errors.
- **Alerting** — email/Teams/Slack notifications on deployment completion or failure.

### Advanced Unattend.xml Management
- **Visual unattend builder** — form-based editor for all unattend.xml settings instead of raw XML.
- **Pass-aware editing** — clearly separate specialize, oobeSystem, and windowsPE pass settings.
- **Template library** — pre-built unattend templates for common scenarios (Autopilot, domain join, kiosk mode).
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
- **Keyboard navigation** — full keyboard support for all operations (already partial with Delete key).
- **Screen reader support** — announce state changes (step selected, saved, etc.).
- **High contrast mode** — alternative theme for accessibility.

---

## Implementation Priority

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| 🔴 P0 | Dashboard overview page | Medium | High |
| 🔴 P0 | Breadcrumb navigation | Low | High |
| 🟡 P1 | Step validation warnings | Medium | High |
| 🟡 P1 | Dirty state / unsaved indicator | Low | Medium |
| 🟡 P1 | Auto-save drafts to localStorage | Low | Medium |
| 🟢 P2 | Step groups / folders | High | High |
| 🟢 P2 | Conditional logic (if/else) | High | High |
| 🟢 P2 | Visual unattend builder | High | Medium |
| 🔵 P3 | Deployment simulation | High | Medium |
| 🔵 P3 | TypeScript migration | High | Medium |
| 🔵 P3 | Real-time collaboration | Very High | Medium |
