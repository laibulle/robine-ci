const livePipeline = document.querySelector("[data-live-pipeline]")

document.addEventListener("click", async event => {
  const button = event.target.closest("[data-copy-target]")
  if (!button) return
  const source = document.getElementById(button.dataset.copyTarget)
  if (!source || !navigator.clipboard) return
  await navigator.clipboard.writeText(source.textContent.trim())
  button.textContent = "Copied"
})

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

const liveJob = document.querySelector("[data-live-job]")

if (liveJob && window.EventSource) {
  const source = new EventSource(liveJob.dataset.eventsUrl)
  const feedback = document.querySelector("#job-log-result-feedback")
  let initialized = false

  const appendChunk = log => {
    const id = `log-${log.attempt_number}-${log.sequence}`
    if (document.getElementById(id)) return false
    let phase = document.querySelector(`[data-log-phase][data-attempt="${CSS.escape(String(log.attempt_number))}"][data-phase="${CSS.escape(log.phase || "execution")}"]`)
    if (!phase) {
      phase = document.createElement("section")
      phase.className = "log-phase"
      phase.dataset.logPhase = ""
      phase.dataset.attempt = String(log.attempt_number)
      phase.dataset.phase = log.phase || "execution"
      const heading = document.createElement("h3")
      heading.textContent = `Attempt ${log.attempt_number} · ${log.phase || "execution"} phase`
      phase.append(heading)
      document.querySelector("#job-log-window")?.append(phase)
    }
    let step = phase.querySelector(`[data-log-step][data-position="${CSS.escape(String(log.step_position))}"]`)
    if (!step) {
      step = document.createElement("details")
      step.className = log.step_status === "failed" ? "log-step failed" : "log-step"
      step.open = log.step_status === "failed"
      step.dataset.logStep = ""
      step.dataset.position = String(log.step_position)
      const summary = document.createElement("summary")
      const name = document.createElement("strong")
      name.textContent = log.step_name || "step"
      const state = document.createElement("span")
      state.textContent = `${log.step_status || "unknown"} · `
      const count = document.createElement("span")
      count.dataset.logCount = ""
      count.textContent = "0"
      state.append(count, " chunks")
      const chunks = document.createElement("ol")
      chunks.dataset.logChunks = ""
      summary.append(name, state)
      step.append(summary, chunks)
      phase.append(step)
    }
    const item = document.createElement("li")
    item.id = id
    const metadata = document.createElement("span")
    metadata.className = "meta"
    metadata.textContent = `${log.stream || "combined"} · sequence ${log.sequence}`
    const content = document.createElement("pre")
    content.textContent = log.content || ""
    item.append(metadata, content)
    step.querySelector("[data-log-chunks]")?.append(item)
    const count = step.querySelector("[data-log-count]")
    if (count) count.textContent = String(step.querySelectorAll("[id^='log-']").length)
    return true
  }

  source.addEventListener("logs", event => {
    const logs = JSON.parse(event.data)
    if (!initialized) {
      initialized = true
      return
    }
    const unseen = logs.filter(log => !document.getElementById(`log-${log.attempt_number}-${log.sequence}`))
    if (liveJob.dataset.filtered === "true") {
      if (unseen.length && feedback) feedback.textContent = "New logs are available. Clear filters to resume the live view."
      return
    }
    const appended = unseen.reduce((count, log) => count + Number(appendChunk(log)), 0)
    const chunks = [...document.querySelectorAll("#job-log-window [id^='log-']")]
    chunks.slice(0, Math.max(0, chunks.length - 50)).forEach(chunk => chunk.remove())
    if (appended && feedback) feedback.textContent = `Live log updated with ${appended} new chunk${appended === 1 ? "" : "s"}.`
  })

  source.addEventListener("unavailable", () => {
    if (feedback) feedback.textContent = "Live logs are temporarily unavailable; retained output remains readable."
  })
  source.onerror = () => {
    if (feedback) feedback.textContent = "Live log connection interrupted; reconnecting automatically."
  }
  window.addEventListener("pagehide", () => source.close(), {once: true})
}
