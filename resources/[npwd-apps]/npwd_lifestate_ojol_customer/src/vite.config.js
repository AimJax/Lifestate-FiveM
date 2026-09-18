import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import federation from '@originjs/vite-plugin-federation'

export default defineConfig({
  plugins: [
    react(),
    federation({
      name: 'npwd_lifestate_ojol_customer',
      filename: 'remoteEntry.js',
      exposes: {
        './config': './config.jsx'
      },
      shared: ['react', 'react-dom']
    })
  ],
  build: {
    target: 'es2022',
    outDir: '../web/dist',
    emptyOutDir: true,
    assetsDir: '',
    minify: false,
    cssCodeSplit: false
  },
  resolve: {
    alias: {
      '@': '/src'
    }
  }
})
