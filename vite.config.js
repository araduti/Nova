import { defineConfig } from 'vite';
import { resolve } from 'path';
import { cpSync, existsSync } from 'fs';

/**
 * Vite configuration for AmpCloud web UIs.
 *
 * Builds the Editor, Monitoring, and root dashboard pages for GitHub
 * Pages deployment.  Static config/data files (Config/, TaskSequence/,
 * Unattend/) are copied to the output directory so runtime `fetch()`
 * calls resolve correctly.
 *
 * NOTE: AmpCloud-UI and Progress are embedded into WinPE by Trigger.ps1
 * and run offline — they are NOT part of this build.
 */
export default defineConfig({
  base: '/AmpCloud/',
  build: {
    outDir: 'dist',
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        editor: resolve(__dirname, 'Editor/index.html'),
        monitoring: resolve(__dirname, 'Monitoring/index.html'),
      },
    },
  },
  plugins: [
    {
      name: 'copy-static-assets',
      closeBundle() {
        const copies = [
          /* Runtime config fetched by JS at load time */
          ['Config', 'dist/Config'],
          ['TaskSequence', 'dist/TaskSequence'],
          ['Unattend', 'dist/Unattend'],
          /* Editor non-module scripts (not processed by Vite) */
          ['Editor/js', 'dist/Editor/js'],
          ['Editor/lib', 'dist/Editor/lib'],
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
