const livePipeline = document.querySelector("[data-live-pipeline]")

if (livePipeline && window.EventSource) {
  const source = new EventSource(livePipeline.dataset.eventsUrl)
  let initialSnapshot = true

  source.addEventListener("pipeline", () => {
    if (initialSnapshot) {
      initialSnapshot = false
    } else {
      source.close()
      window.location.reload()
    }
  })

  window.addEventListener("pagehide", () => source.close(), {once: true})
}
