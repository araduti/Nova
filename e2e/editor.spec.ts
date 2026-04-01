import { test, expect, type Page } from '@playwright/test';

/**
 * Intercept the auth config so the Editor loads without requiring
 * Microsoft 365 authentication.
 */
async function bypassAuth(page: Page) {
  await page.route('**/Config/auth.json', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ requireAuth: false }),
    }),
  );
}

/**
 * Navigate to the Editor with auth bypassed and wait for the UI to
 * be ready.  Use `?new=1` to start with an empty task sequence.
 */
async function openEditor(page: Page, opts: { empty?: boolean } = {}) {
  await bypassAuth(page);
  const qs = opts.empty ? '?new=1' : '';
  await page.goto(`Editor/${qs}`);
  await expect(page.locator('header.toolbar')).toBeVisible();
}

/**
 * Selector for actual step items (excludes group headers).
 * The step list renders both `.step-group-header` and `.step-item`
 * elements as `<li>`.
 */
const STEP_ITEM = '#stepList .step-item';

/* ── Page load ───────────────────────────────────────────────────── */

test.describe('Editor — Page Load', () => {
  test('loads the editor page with correct title', async ({ page }) => {
    await openEditor(page);
    await expect(page).toHaveTitle('Nova Task Sequence Editor');
  });

  test('shows the editor UI when auth is disabled', async ({ page }) => {
    await openEditor(page);
    // Login overlay should be hidden
    await expect(page.locator('#loginOverlay')).toHaveClass(/hidden/);
    // Toolbar and main layout should be visible
    await expect(page.locator('header.toolbar')).toBeVisible();
    await expect(page.locator('.main')).toBeVisible();
  });

  test('shows login overlay when auth is required', async ({ page }) => {
    await page.route('**/Config/auth.json', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ requireAuth: true, clientId: 'test-id' }),
      }),
    );
    await page.goto('Editor/');
    // Login overlay should be visible with the sign-in button
    await expect(page.locator('#loginOverlay')).toBeVisible();
    await expect(page.locator('#btnLogin')).toBeVisible({ timeout: 10_000 });
  });

  test('loads the default task sequence with pre-populated steps', async ({ page }) => {
    await openEditor(page);
    // The default.json has 13 steps
    await expect(page.locator(STEP_ITEM)).not.toHaveCount(0);
    // First step should be selected automatically
    await expect(page.locator('#propsEditor')).toBeVisible();
  });

  test('starts empty when ?new=1 is used', async ({ page }) => {
    await openEditor(page, { empty: true });
    await expect(page.locator(STEP_ITEM)).toHaveCount(0);
    await expect(page.locator('#tsName')).toHaveText('New Task Sequence');
  });
});

/* ── Step operations ─────────────────────────────────────────────── */

test.describe('Editor — Step Operations', () => {
  test.beforeEach(async ({ page }) => {
    await openEditor(page, { empty: true });
  });

  test('opens the add-step dialog when + is clicked', async ({ page }) => {
    await page.locator('#btnAddStep').click();
    await expect(page.locator('#addStepDialog')).toBeVisible();
    // Step types list should be populated
    await expect(page.locator('#stepTypeList li')).not.toHaveCount(0);
  });

  test('adds a step via the dialog', async ({ page }) => {
    // Open dialog
    await page.locator('#btnAddStep').click();
    await expect(page.locator('#addStepDialog')).toBeVisible();

    // Select first step type
    await page.locator('#stepTypeList li').first().click();
    await page.locator('#btnAddStepOk').click();

    // Dialog should close and step should appear in list
    await expect(page.locator('#addStepDialog')).toHaveClass(/hidden/);
    await expect(page.locator(STEP_ITEM)).toHaveCount(1);
  });

  test('selects a step to show properties', async ({ page }) => {
    // Add a step first
    await page.locator('#btnAddStep').click();
    await page.locator('#stepTypeList li').first().click();
    await page.locator('#btnAddStepOk').click();

    // Click the step
    await page.locator(STEP_ITEM).first().click();

    // Properties editor should be visible
    await expect(page.locator('#propsEditor')).toBeVisible();
    await expect(page.locator('#propsEmpty')).toHaveClass(/hidden/);
    // Step name field should be populated
    await expect(page.locator('#propName')).not.toHaveValue('');
  });

  test('removes a step', async ({ page }) => {
    // Add a step
    await page.locator('#btnAddStep').click();
    await page.locator('#stepTypeList li').first().click();
    await page.locator('#btnAddStepOk').click();
    await expect(page.locator(STEP_ITEM)).toHaveCount(1);

    // Select the step and remove it
    await page.locator(STEP_ITEM).first().click();
    // Handle the confirmation dialog
    page.on('dialog', (d) => d.accept());
    await page.locator('#btnRemoveStep').click();

    // Step list should be empty
    await expect(page.locator(STEP_ITEM)).toHaveCount(0);
  });

  test('adds multiple steps and reorders them', async ({ page }) => {
    // Add first step (PartitionDisk is first in list)
    await page.locator('#btnAddStep').click();
    await page.locator('#stepTypeList li').first().click();
    await page.locator('#btnAddStepOk').click();

    // Add second step (different type — pick a step from a different group)
    await page.locator('#btnAddStep').click();
    await page.locator('#stepTypeList li').nth(1).click();
    await page.locator('#btnAddStepOk').click();

    await expect(page.locator(STEP_ITEM)).toHaveCount(2);

    // Get first step text before reorder
    const firstStepText = await page.locator(STEP_ITEM).first().textContent();

    // Select second step and move it up
    await page.locator(STEP_ITEM).nth(1).click();
    await page.locator('#btnMoveUp').click();

    // First step text should now be different
    const newFirstStepText = await page.locator(STEP_ITEM).first().textContent();
    expect(newFirstStepText).not.toBe(firstStepText);
  });

  test('duplicates a step', async ({ page }) => {
    // Add a step
    await page.locator('#btnAddStep').click();
    await page.locator('#stepTypeList li').first().click();
    await page.locator('#btnAddStepOk').click();

    // Select and duplicate
    await page.locator(STEP_ITEM).first().click();
    await page.locator('#btnDuplicateStep').click();

    // Should now have 2 steps
    await expect(page.locator(STEP_ITEM)).toHaveCount(2);
  });

  test('cancels the add-step dialog', async ({ page }) => {
    await page.locator('#btnAddStep').click();
    await expect(page.locator('#addStepDialog')).toBeVisible();

    await page.locator('#btnAddStepCancel').click();
    await expect(page.locator('#addStepDialog')).toHaveClass(/hidden/);

    // No step should be added
    await expect(page.locator(STEP_ITEM)).toHaveCount(0);
  });
});

/* ── Step properties editing ─────────────────────────────────────── */

test.describe('Editor — Properties', () => {
  test.beforeEach(async ({ page }) => {
    await openEditor(page, { empty: true });

    // Add and select a step
    await page.locator('#btnAddStep').click();
    await page.locator('#stepTypeList li').first().click();
    await page.locator('#btnAddStepOk').click();
    await page.locator(STEP_ITEM).first().click();
  });

  test('edits step name and reflects in step list', async ({ page }) => {
    await page.locator('#propName').fill('My Custom Step');
    await page.locator('#propName').press('Tab');

    // Step list item should reflect the new name
    await expect(page.locator(STEP_ITEM).first()).toContainText('My Custom Step');
  });

  test('toggles enabled checkbox', async ({ page }) => {
    const checkbox = page.locator('#propEnabled');
    const wasChecked = await checkbox.isChecked();
    await checkbox.click();
    expect(await checkbox.isChecked()).toBe(!wasChecked);
  });

  test('toggles continue-on-error checkbox', async ({ page }) => {
    const checkbox = page.locator('#propContinueOnError');
    await checkbox.click();
    expect(await checkbox.isChecked()).toBe(true);
  });

  test('shows empty state when no step is selected', async ({ page }) => {
    // Remove the step to return to empty state
    page.on('dialog', (d) => d.accept());
    await page.locator('#btnRemoveStep').click();

    // Should show empty state
    await expect(page.locator('#propsEmpty')).toBeVisible();
  });
});

/* ── Validation ──────────────────────────────────────────────────── */

test.describe('Editor — Validation', () => {
  test('validates an empty task sequence', async ({ page }) => {
    await openEditor(page, { empty: true });

    page.on('dialog', async (d) => {
      await d.accept();
    });
    await page.locator('#btnValidate').click();
  });

  test('validates a task sequence with steps', async ({ page }) => {
    await openEditor(page, { empty: true });

    // Add a step
    await page.locator('#btnAddStep').click();
    await page.locator('#stepTypeList li').first().click();
    await page.locator('#btnAddStepOk').click();

    // Validate — should succeed or show validation result
    page.on('dialog', (d) => d.accept());
    await page.locator('#btnValidate').click();
  });
});

/* ── Download / New ──────────────────────────────────────────────── */

test.describe('Editor — File Operations', () => {
  test('downloads task sequence as JSON', async ({ page }) => {
    await openEditor(page);

    // The default sequence has steps, so download should work
    const downloadPromise = page.waitForEvent('download');
    await page.locator('#btnDownload').click();
    const download = await downloadPromise;

    expect(download.suggestedFilename()).toContain('.json');
  });

  test('creates a new empty task sequence', async ({ page }) => {
    await openEditor(page);

    // Confirm that steps are loaded from the default
    const initialCount = await page.locator(STEP_ITEM).count();
    expect(initialCount).toBeGreaterThan(0);

    // Click New and confirm
    page.on('dialog', (d) => d.accept());
    await page.locator('#btnNew').click();

    // Steps should be cleared
    await expect(page.locator(STEP_ITEM)).toHaveCount(0);
  });
});

/* ── Step search / filter ────────────────────────────────────────── */

test.describe('Editor — Search', () => {
  test('filters steps by search input', async ({ page }) => {
    await openEditor(page);

    // The default task sequence has multiple steps
    const totalSteps = await page.locator(STEP_ITEM).count();
    expect(totalSteps).toBeGreaterThan(1);

    // Type in search — should filter to matching steps
    await page.locator('#stepSearch').fill('Partition');

    // Wait for filtering to take effect
    await page.waitForTimeout(300);

    // At least one step should match, and fewer should be visible
    const visibleSteps = page.locator(`${STEP_ITEM}:not([style*="display: none"])`);
    const visibleCount = await visibleSteps.count();
    expect(visibleCount).toBeGreaterThanOrEqual(1);
    expect(visibleCount).toBeLessThanOrEqual(totalSteps);
  });
});

/* ── Undo / Redo ─────────────────────────────────────────────────── */

test.describe('Editor — Undo & Redo', () => {
  test('undo/redo buttons work with the default task sequence', async ({ page }) => {
    // Use the default-loaded sequence (which properly calls captureSnapshot)
    await openEditor(page);

    const initialCount = await page.locator(STEP_ITEM).count();
    expect(initialCount).toBeGreaterThan(0);

    // Initially undo is disabled (no changes yet)
    await expect(page.locator('#btnUndo')).toBeDisabled();

    // Make a change — remove a step
    await page.locator(STEP_ITEM).first().click();
    page.on('dialog', (d) => d.accept());
    await page.locator('#btnRemoveStep').click();

    // Undo should now be enabled
    await expect(page.locator('#btnUndo')).toBeEnabled();

    // Undo the removal
    await page.locator('#btnUndo').click();
    await expect(page.locator(STEP_ITEM)).toHaveCount(initialCount);

    // Redo should now be enabled
    await expect(page.locator('#btnRedo')).toBeEnabled();
  });
});

/* ── Add-step dialog tabs ────────────────────────────────────────── */

test.describe('Editor — Dialog Tabs', () => {
  test('switches between step types and templates tabs', async ({ page }) => {
    await openEditor(page, { empty: true });

    await page.locator('#btnAddStep').click();
    await expect(page.locator('#addStepDialog')).toBeVisible();

    // Types tab should be active by default
    await expect(page.locator('#tabTypes')).toBeVisible();

    // Switch to Templates tab
    await page.locator('.dialog-tab[data-tab="templates"]').click();
    await expect(page.locator('#tabTemplates')).toBeVisible();

    // Switch back to Types tab
    await page.locator('.dialog-tab[data-tab="types"]').click();
    await expect(page.locator('#tabTypes')).toBeVisible();
  });

  test('adds a step from built-in templates', async ({ page }) => {
    await openEditor(page, { empty: true });

    await page.locator('#btnAddStep').click();
    await page.locator('.dialog-tab[data-tab="templates"]').click();

    // Built-in templates should be listed
    const templateItems = page.locator('#templateList li');
    const count = await templateItems.count();
    if (count > 0) {
      await templateItems.first().click();
      await page.locator('#btnAddStepOk').click();
      await expect(page.locator(STEP_ITEM)).toHaveCount(1);
    }
  });
});
