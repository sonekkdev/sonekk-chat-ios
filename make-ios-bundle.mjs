// Inlines the web bundle into a single HTML file. WKWebView cannot load ES modules
// from file://, but inline module scripts are fine.
import fs from 'node:fs'
import path from 'node:path'

const root = path.resolve('web')
const outDir = path.resolve('web-ios')
fs.mkdirSync(outDir, { recursive: true })

let html = fs.readFileSync(path.join(root, 'index.html'), 'utf8')
const iosShim = fs.readFileSync(path.join(root, 'shim-ios.js'), 'utf8')
const androidShim = fs.readFileSync(path.join(root, 'shim.js'), 'utf8')

const cssMatch = html.match(/<link[^>]+href="\.\/(assets\/[^"]+\.css)"[^>]*>/)
const jsMatch = html.match(/<script type="module"[^>]+src="\.\/(assets\/[^"]+\.js)"[^>]*><\/script>/)
if (!cssMatch || !jsMatch) throw new Error('bundle layout not recognised')

const css = fs.readFileSync(path.join(root, cssMatch[1]), 'utf8')
const js = fs.readFileSync(path.join(root, jsMatch[1]), 'utf8')

html = html.replace(cssMatch[0], `<style>\n${css}\n</style>`)
html = html.replace(jsMatch[0], [
  '<script>',
  iosShim,
  '</script>',
  '<script>',
  androidShim,
  '</script>',
  '<script type="module">',
  js,
  '</script>'
].join('\n'))

fs.writeFileSync(path.join(outDir, 'index.html'), html)
console.log(`single file bundle: ${(html.length / 1024).toFixed(1)} KB`)
