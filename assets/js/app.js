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
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/robine"
import topbar from "../vendor/topbar"

const systemTheme = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"

const setTheme = theme => {
  if (theme === "system") {
    localStorage.removeItem("phx:theme")
    document.documentElement.setAttribute("data-theme", systemTheme())
    document.documentElement.setAttribute("data-theme-source", "system")
  } else {
    localStorage.setItem("phx:theme", theme)
    document.documentElement.setAttribute("data-theme", theme)
    document.documentElement.setAttribute("data-theme-source", "user")
  }
}

if (!document.documentElement.hasAttribute("data-theme")) {
  setTheme(localStorage.getItem("phx:theme") || "system")
}

window.addEventListener("storage", event => {
  if (event.key === "phx:theme") setTheme(event.newValue || "system")
})
window.addEventListener("phx:set-theme", event => setTheme(event.target.dataset.phxTheme))
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (document.documentElement.getAttribute("data-theme-source") === "system") {
    document.documentElement.setAttribute("data-theme", systemTheme())
  }
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const LogViewport = {
  mounted() {
    if (this.el.dataset.live === "true") this.el.scrollTop = this.el.scrollHeight
  },
  beforeUpdate() {
    this.scrollTop = this.el.scrollTop
    this.followTail = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 32
  },
  updated() {
    if (this.el.dataset.live === "true" && this.followTail) {
      this.el.scrollTop = this.el.scrollHeight
    } else {
      this.el.scrollTop = this.scrollTop
    }
  },
}

const RetainedLogViewer = {
  mounted() {
    this.abortController = new AbortController()
    this.load()
  },
  destroyed() {
    this.abortController.abort()
  },
  async load() {
    const status = this.el.querySelector("[data-log-status]")
    const output = this.el.querySelector("[data-log-output]")
    const text = document.createTextNode("")
    output.replaceChildren(text)

    try {
      const response = await fetch(this.el.dataset.url, {
        signal: this.abortController.signal,
      })

      if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`)

      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let bytes = 0

      while (true) {
        const {done, value} = await reader.read()
        if (done) break
        bytes += value.byteLength
        text.appendData(decoder.decode(value, {stream: true}))
      }

      text.appendData(decoder.decode())
      status.textContent = bytes === 0 ? "Empty" : "Complete"
    } catch (error) {
      if (error.name !== "AbortError") {
        status.textContent = "Unavailable"
        text.appendData(`Unable to load retained logs: ${error.message}`)
      }
    }
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, LogViewport, RetainedLogViewer},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => {
  topbar.show(300)
  document.querySelector("#main-content")?.setAttribute("aria-busy", "true")
  const status = document.querySelector("#page-loading-status")
  if (status) status.textContent = "Loading content"
})
window.addEventListener("phx:page-loading-stop", _info => {
  topbar.hide()
  document.querySelector("#main-content")?.setAttribute("aria-busy", "false")
  const status = document.querySelector("#page-loading-status")
  if (status) status.textContent = "Content loaded"
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
