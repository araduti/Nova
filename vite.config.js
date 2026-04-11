import { defineConfig } from 'vite';
import { resolve } from 'path';
import { cpSync, existsSync } from 'fs';

/**
 * Vite configuration for Nova web UIs.
 *
 * Builds the Editor, Monitoring, and root dashboard pages for GitHub
 * Pages deployment.  Static config/data files (config/, resources/)
 * are copied to the output directory so runtime `fetch()` calls
 * resolve correctly.
 *
 * NOTE: Nova-UI and Progress are embedded into WinPE by Trigger.ps1
 * and run offline — they are NOT part of this build.
 */
export default defineConfig({
  base: '/',
  build: {
    outDir: 'dist',
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        editor: resolve(__dirname, 'src/web/editor/index.html'),
        monitoring: resolve(__dirname, 'src/web/monitoring/index.html'),
      },
    },
  },
  plugins: [
    {
      name: 'copy-static-assets',
      closeBundle() {
        const copies = [
          /* Runtime config fetched by JS at load time */
          ['config', 'dist/config'],
          ['resources/task-sequence', 'dist/resources/task-sequence'],
          ['resources/unattend', 'dist/resources/unattend'],
          /* Editor non-module scripts (not processed by Vite) */
          ['src/web/editor/js', 'dist/src/web/editor/js'],
          ['src/web/editor/lib', 'dist/src/web/editor/lib'],
          /* PowerShell entry point for irm <url> | iex one-liner */
          ['src/scripts/Trigger.ps1', 'dist/Trigger.ps1'],
          /* Custom domain file for GitHub Pages */
          ['CNAME', 'dist/CNAME'],
        ];
        for (const [src, dest] of copies) {
          if (existsSync(src)) {
            cpSync(src, dest, { recursive: true });
          }
        }
      },
    },
  ],
});
