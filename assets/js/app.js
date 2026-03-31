import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let mermaidPromise

let loadMermaid = async () => {
  if (!mermaidPromise) {
    mermaidPromise = import("https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs").then(
      (module) => {
        let mermaid = module.default
        mermaid.initialize({startOnLoad: false})
        return mermaid
      }
    )
  }

  return mermaidPromise
}

let Hooks = {}

Hooks.MermaidDiagram = {
  mounted() {
    this.resizeHandler = null
    this.renderDiagram()
  },

  updated() {
    this.renderDiagram()
  },

  destroyed() {
    if (this.resizeHandler) {
      window.removeEventListener("resize", this.resizeHandler)
      this.resizeHandler = null
    }
  },

  async renderDiagram() {
    let diagram = this.el.dataset.diagram

    if (!diagram) {
      this.el.innerHTML = ""
      return
    }

    if (this.el.offsetWidth === 0) {
      if (!this.resizeHandler) {
        this.resizeHandler = () => {
          this.resizeHandler = null
          this.renderDiagram()
        }

        window.addEventListener("resize", this.resizeHandler, {once: true})
      }

      return
    }

    if (this.resizeHandler) {
      window.removeEventListener("resize", this.resizeHandler)
      this.resizeHandler = null
    }

    try {
      let mermaid = await loadMermaid()
      let renderId = `ogol-machine-diagram-${this.el.id || "graph"}`
      let {svg, bindFunctions} = await mermaid.render(renderId, diagram)

      this.el.innerHTML = ""

      let container = document.createElement("div")
      container.classList.add("machine-mermaid-container")

      let figure = document.createElement("figure")
      figure.classList.add("machine-mermaid-figure")
      figure.innerHTML = svg.replace(/<br>/gi, "<br/>")
      container.appendChild(figure)
      this.el.appendChild(container)

      let svgEl = figure.querySelector("svg")

      if (svgEl) {
        if (svgEl.style.maxWidth) {
          svgEl.style.width = svgEl.style.maxWidth
        }

        svgEl.style.maxWidth = "100%"
        svgEl.removeAttribute("height")
      }

      if (bindFunctions) {
        bindFunctions(this.el)
      }
    } catch (error) {
      this.el.innerHTML =
        `<div class="machine-mermaid-error">Diagram render failed: ${error}</div>`
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: {_csrf_token: csrfToken}
})

liveSocket.connect()

window.liveSocket = liveSocket
