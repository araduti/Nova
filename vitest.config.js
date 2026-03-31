import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['Editor/test/**/*.test.js'],
  },
});
