const livePipeline = document.querySelector("[data-live-pipeline]")

if (livePipeline && window.EventSource) {
  const source = new EventSource(livePipeline.dataset.eventsUrl)

  source.addEventListener("pipeline", event => {
    const projection = JSON.parse(event.data)
    const pipelineStatus = document.querySelector("#pipeline-status")
    if (pipelineStatus && projection.status) pipelineStatus.textContent = projection.status
    for (const job of projection.jobs || []) {
      const row = document.querySelector(`[data-job-id="${CSS.escape(job.id)}"]`)
      const status = row?.querySelector("[data-job-status]")
      if (status && job.status) status.textContent = job.status
    }
    const state = document.querySelector("#pipeline-live-state")
    if (state) state.textContent = "Pipeline state updated."
  })

  source.addEventListener("unavailable", () => {
    const state = document.querySelector("#pipeline-live-state")
    if (state) state.textContent = "Live updates are temporarily unavailable; existing state remains visible and reconnection is automatic."
  })

  source.onerror = () => {
    const state = document.querySelector("#pipeline-live-state")
    if (state) state.textContent = "Live connection interrupted; reconnecting automatically."
  }

  window.addEventListener("pagehide", () => source.close(), {once: true})
}
