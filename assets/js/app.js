// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Copy text to the clipboard. Falls back to a hidden textarea +
// execCommand because the async Clipboard API is unavailable on insecure
// origins (the CTF is served over plain http), where it would otherwise
// silently reject.
function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    return navigator.clipboard.writeText(text)
  }
  return new Promise((resolve, reject) => {
    const ta = document.createElement("textarea")
    ta.value = text
    ta.setAttribute("readonly", "")
    ta.style.position = "fixed"
    ta.style.top = "-1000px"
    ta.style.opacity = "0"
    document.body.appendChild(ta)
    ta.select()
    try {
      document.execCommand("copy") ? resolve() : reject(new Error("copy rejected"))
    } catch (err) {
      reject(err)
    } finally {
      ta.remove()
    }
  })
}

// Briefly swap a button's label to give feedback, then restore it.
function flashLabel(btn, message) {
  if (btn._revert) {
    clearTimeout(btn._revert)
  } else {
    btn._label = btn.textContent
  }
  btn.textContent = message
  btn._revert = setTimeout(() => {
    btn.textContent = btn._label
    btn._revert = null
  }, 1500)
}

function copyToButton(btn, text) {
  copyText(text)
    .then(() => flashLabel(btn, "Copied!"))
    .catch(() => flashLabel(btn, "Press Ctrl+C"))
}

function downloadText(text, filename) {
  const blob = new Blob([text], {type: "application/octet-stream"})
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = filename || "download.txt"
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}

let Hooks = {}

// Server-rendered code box (see CoreComponents.code_block/1): wires its
// copy and optional download buttons.
Hooks.CodeBlock = {
  mounted() {
    const codeEl = this.el.querySelector("[data-code]")
    const copyBtn = this.el.querySelector("[data-copy]")
    const downloadBtn = this.el.querySelector("[data-download]")

    if (copyBtn) {
      copyBtn.addEventListener("click", () => copyToButton(copyBtn, codeEl.innerText))
    }
    if (downloadBtn) {
      downloadBtn.addEventListener("click", () =>
        downloadText(codeEl.innerText, downloadBtn.dataset.filename)
      )
    }
  }
}

// Decorates every <pre> inside a container (e.g. rendered markdown) with a
// copy button. Copy only — these aren't files, so no download.
Hooks.CodeFences = {
  mounted() {
    this.decorate()
  },
  updated() {
    this.decorate()
  },
  decorate() {
    this.el.querySelectorAll("pre").forEach((pre) => {
      if (pre.dataset.copyDecorated) return
      pre.dataset.copyDecorated = "1"

      // Capture the code before adding the button so the button text can't
      // leak into what we copy.
      const code = pre.innerText

      pre.classList.add("relative")
      const btn = document.createElement("button")
      btn.type = "button"
      btn.textContent = "Copy"
      btn.className =
        "absolute right-2 top-2 rounded bg-gray-700/90 px-2 py-1 text-xs font-semibold text-gray-100 hover:bg-gray-600"
      btn.addEventListener("click", () => copyToButton(btn, code))
      pre.appendChild(btn)
    })
  }
}

// The Vega runtime is a separate esbuild entry point (~812KB), so it is fetched
// the first time a chart mounts rather than on every page load. The promise is
// memoized: a second chart on the page waits on the same request.
let vegaRuntime = null
function loadVega() {
  if (!vegaRuntime) {
    vegaRuntime = new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = "/assets/vega.js"
      script.onload = () => resolve(window.vegaEmbed)
      script.onerror = () => {
        vegaRuntime = null // let a later mount retry rather than fail forever
        reject(new Error("could not load the chart runtime"))
      }
      document.head.appendChild(script)
    })
  }
  return vegaRuntime
}

// Renders a Vega-Lite spec built server-side and handed over in data-spec.
// The element is phx-update="ignore", so LiveView patches that attribute but
// leaves the rendered SVG alone.
Hooks.VegaChart = {
  mounted() {
    this.draw()
    // Vega only measures the container once, so a resized window would keep the
    // original width until the next server update. Redraw on real width changes,
    // ignoring sub-pixel noise.
    if (window.ResizeObserver) {
      this.lastWidth = this.el.clientWidth
      this.observer = new ResizeObserver(() => {
        const width = this.el.clientWidth
        if (Math.abs(width - this.lastWidth) > 8) {
          this.lastWidth = width
          this.draw()
        }
      })
      this.observer.observe(this.el)
    }
  },
  updated() { this.draw() },
  destroyed() {
    if (this.observer) { this.observer.disconnect(); this.observer = null }
    this.teardown()
  },

  async draw() {
    // Each draw claims a token; if another one starts while this is awaiting
    // (a score lands mid-render), the stale draw discards its result.
    const token = {}
    this.token = token

    let spec
    try {
      spec = JSON.parse(this.el.dataset.spec)
    } catch (_error) {
      return
    }

    // The spec asks for width:"container", but vega-embed injects a stylesheet
    // making its own wrapper display:inline-block — which shrink-to-fits to zero
    // before it has content. Vega then measures 0 and renders a zero-width SVG:
    // the chart "loads" and draws nothing at all. Measure the real container
    // ourselves and hand Vega a concrete pixel width instead.
    const width = Math.max(320, Math.floor(this.el.clientWidth))
    if (width > 0) { spec.width = width }

    let embed
    try {
      embed = await loadVega()
    } catch (_error) {
      this.el.textContent = "The chart could not be loaded. The standings table below is complete."
      return
    }
    if (this.token !== token) { return }

    const result = await embed(this.el, spec, {actions: false, renderer: "svg"})
    if (this.token !== token) { result.view.finalize(); return }

    this.teardown()
    this.view = result.view
  },

  teardown() {
    if (this.view) {
      this.view.finalize()
      this.view = null
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

