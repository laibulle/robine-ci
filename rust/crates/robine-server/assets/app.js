const livePipeline = document.querySelector("[data-live-pipeline]")

const durationLabel = milliseconds => {
  if (milliseconds == null) return "Not started"
  const total = Math.max(0, Math.floor(milliseconds / 1000))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const seconds = total % 60
  if (hours > 0) return `${hours}h ${minutes}m ${seconds}s`
  if (minutes > 0) return `${minutes}m ${seconds}s`
  return `${seconds}s`
}

if (livePipeline && window.EventSource) {
  const source = new EventSource(livePipeline.dataset.eventsUrl)

  source.addEventListener("pipeline", event => {
    const projection = JSON.parse(event.data)
    const pipelineStatus = document.querySelector("#pipeline-status")
    if (pipelineStatus && projection.status) pipelineStatus.textContent = projection.status
    const pipelineDuration = document.querySelector("#pipeline-duration")
    if (pipelineDuration) pipelineDuration.textContent = durationLabel(projection.duration_ms)
    for (const job of projection.jobs || []) {
      const row = document.querySelector(`[data-job-id="${CSS.escape(job.id)}"]`)
      const status = row?.querySelector("[data-job-status]")
      if (status && job.status) status.textContent = job.status
      const phase = row?.querySelector("[data-job-phase]")
      if (phase) phase.textContent = job.latest_phase || "Waiting"
      const duration = row?.querySelector("[data-job-duration]")
      if (duration) duration.textContent = durationLabel(job.duration_ms)
      const reason = row?.querySelector("[data-job-reason]")
      if (reason) reason.textContent = job.terminal_reason || "None"
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
