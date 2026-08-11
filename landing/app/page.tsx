const Check = () => <span aria-hidden="true">✓</span>;
const Arrow = () => <span aria-hidden="true">↗</span>;

const jobs = [
  { name: "test", detail: "Unit & integration", time: "01:42", active: false },
  { name: "build", detail: "Container image", time: "00:48", active: false },
  { name: "publish", detail: "Artifacts retained", time: "done", active: true },
];

const features = [
  {
    number: "01",
    icon: "⌁",
    title: "Reproduce every run locally.",
    text: "The same workflow rules, images, services, and conditions in CI and on your machine. Debug without guesswork.",
  },
  {
    number: "02",
    icon: "◇",
    title: "Keep your code yours.",
    text: "Code, secrets, caches, and artifacts stay on infrastructure you control. No opaque execution layer in the middle.",
  },
  {
    number: "03",
    icon: "≋",
    title: "Read the signal, not the noise.",
    text: "Clear pipeline states, focused logs, and explicit failure reasons help your team move from red to resolved quickly.",
  },
];

function Brand({ dark = false }: { dark?: boolean }) {
  return (
    <span className="flex items-center gap-3 font-bold tracking-tight">
      <img
        src={dark ? "/images/brand/robine-mark-dark.png" : "/images/brand/robine-mark.png"}
        alt=""
        className="size-10 object-contain"
      />
      <span>Robine <span className={dark ? "font-medium text-white/35" : "font-medium text-navy/35"}>CI</span></span>
    </span>
  );
}

export default function Home() {
  return (
    <main id="top" className="min-h-screen overflow-hidden bg-canvas text-navy">
      <header className="sticky top-0 z-50 border-b border-line/70 bg-canvas/85 backdrop-blur-xl">
        <div className="mx-auto flex h-20 max-w-7xl items-center justify-between px-5 sm:px-8">
          <a href="#top" aria-label="Robine CI home"><Brand /></a>
          <nav className="hidden items-center gap-8 text-sm font-semibold text-navy/55 md:flex" aria-label="Main navigation">
            <a className="transition hover:text-navy" href="#product">Product</a>
            <a className="transition hover:text-navy" href="#principles">Principles</a>
            <a className="transition hover:text-navy" href="#open-source">Open source</a>
          </nav>
          <a className="btn-primary inline-flex items-center gap-3 rounded-xl bg-teal px-4 py-2.5 text-sm font-bold text-white" href="#get-started">
            Get started <Arrow />
          </a>
        </div>
      </header>

      <section className="px-4 py-5 sm:px-6 sm:py-8">
        <div className="hero-shell relative mx-auto grid min-h-[690px] max-w-7xl items-center gap-14 overflow-hidden rounded-[2rem] border border-line/70 bg-surface px-6 py-16 shadow-panel sm:px-10 lg:grid-cols-[1.03fr_.97fr] lg:px-16 lg:py-20">
          <div className="pointer-events-none absolute -right-40 -top-56 size-[42rem] rounded-full bg-teal/10 blur-3xl" />
          <div className="pointer-events-none absolute -bottom-56 left-[20%] size-[30rem] rounded-full bg-amber/8 blur-3xl" />
          <div className="relative z-10 max-w-2xl">
            <p className="eyebrow">Continuous integration, made legible</p>
            <h1 className="mt-7 text-[3.5rem] font-semibold leading-[.94] tracking-[-.065em] sm:text-7xl lg:text-[5.35rem]">
              Build with speed.<br />
              <span className="text-navy/35">Ship with clarity.</span>
            </h1>
            <p className="mt-7 max-w-xl text-base leading-7 text-navy/60 sm:text-lg sm:leading-8">
              Robine brings trusted repositories, reproducible jobs, and actionable logs into one calm, self-hosted workspace.
            </p>
            <div className="mt-9 flex flex-wrap items-center gap-4">
              <a className="btn-primary inline-flex h-12 items-center gap-3 rounded-xl bg-teal px-6 font-bold text-white" href="#get-started">
                Install Robine <span aria-hidden="true">→</span>
              </a>
              <a className="inline-flex h-12 items-center gap-2 rounded-xl border border-line bg-surface px-5 text-sm font-bold transition hover:-translate-y-0.5 hover:border-teal/35" href="https://github.com" target="_blank" rel="noreferrer">
                View on GitHub <Arrow />
              </a>
            </div>
            <p className="mt-6 flex items-center gap-2 text-sm text-navy/45"><span className="text-teal">●</span> Your infrastructure. Your data.</p>
          </div>

          <div className="relative z-10 mx-auto w-full max-w-xl" aria-label="Pipeline preview">
            <div className="surface-panel rotate-1 rounded-[1.75rem] p-3 transition duration-500 hover:rotate-0 sm:p-5">
              <div className="rounded-2xl border border-line/70 bg-canvas/55 p-5 sm:p-6">
                <div className="flex items-start justify-between gap-4">
                  <div>
                    <p className="text-xs font-bold uppercase tracking-[.14em] text-navy/40">Latest pipeline</p>
                    <h2 className="mt-2 text-xl font-semibold tracking-[-.035em]">Release candidate</h2>
                    <p className="mt-1 font-mono text-xs text-navy/35">main · 8a41cf2d</p>
                  </div>
                  <span className="inline-flex items-center gap-2 rounded-full bg-success/12 px-3 py-1.5 text-xs font-bold text-success"><span className="size-1.5 rounded-full bg-success" />Succeeded</span>
                </div>
                <div className="mt-8 space-y-3">
                  {jobs.map((job) => (
                    <div className={`flex items-center gap-3 rounded-xl border p-4 ${job.active ? "border-teal/25 bg-teal/5" : "border-line/60 bg-surface"}`} key={job.name}>
                      <span className={`grid size-8 shrink-0 place-items-center rounded-full text-sm ${job.active ? "bg-teal text-white" : "bg-success/12 text-success"}`}><Check /></span>
                      <div className="min-w-0 flex-1">
                        <p className="font-semibold">{job.name}</p>
                        <p className="text-xs text-navy/45">{job.detail}</p>
                      </div>
                      <code className={`text-xs ${job.active ? "font-semibold text-teal" : "text-navy/35"}`}>{job.time}</code>
                    </div>
                  ))}
                </div>
                <div className="mt-6 flex items-center justify-between border-t border-line/60 pt-4 text-xs text-navy/45">
                  <span className="flex items-center gap-2"><i className="size-1.5 rounded-full bg-success" /> runner-paris-01</span>
                  <span>3 jobs · 2m 38s</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="mx-auto grid max-w-7xl gap-px overflow-hidden rounded-2xl border border-line bg-line sm:grid-cols-3" aria-label="Product principles">
        {[
          ["⌁", "Trusted execution", "Run reviewed workflows from exact commits."],
          ["›_", "Local reproduction", "Use the same rules locally and in CI."],
          ["▤", "Self-hosted by design", "Your infrastructure remains the boundary."],
        ].map(([icon, title, text]) => (
          <div className="bg-canvas p-6 sm:p-7" key={title}>
            <span className="grid size-9 place-items-center rounded-xl bg-teal/10 font-mono text-sm font-black text-teal">{icon}</span>
            <h2 className="mt-4 font-bold">{title}</h2>
            <p className="mt-1 text-sm leading-6 text-navy/50">{text}</p>
          </div>
        ))}
      </section>

      <section className="mx-auto max-w-7xl px-5 py-28 sm:px-8" id="product">
        <div className="grid gap-8 lg:grid-cols-[.8fr_1.2fr] lg:items-end">
          <p className="eyebrow">A quieter way to ship</p>
          <div>
            <h2 className="text-4xl font-semibold leading-[1.02] tracking-[-.055em] sm:text-6xl">Everything your team needs.<br /><span className="text-navy/35">Nothing it doesn&apos;t.</span></h2>
            <p className="mt-6 max-w-2xl leading-7 text-navy/55">Robine keeps the path from commit to signal short, inspectable, and under your control.</p>
          </div>
        </div>
        <div className="mt-16 grid gap-4 lg:grid-cols-3" id="principles">
          {features.map((feature) => (
            <article className="surface-panel group flex min-h-[350px] flex-col rounded-3xl p-7 transition duration-300 hover:-translate-y-1 hover:border-teal/25" key={feature.number}>
              <div className="flex items-start justify-between">
                <span className="grid size-12 place-items-center rounded-2xl bg-teal/10 font-mono text-xl font-bold text-teal transition group-hover:-rotate-3 group-hover:bg-teal group-hover:text-white">{feature.icon}</span>
                <span className="font-mono text-xs text-navy/30">{feature.number}</span>
              </div>
              <div className="mt-auto pt-16">
                <h3 className="text-2xl font-semibold tracking-[-.04em]">{feature.title}</h3>
                <p className="mt-4 text-sm leading-6 text-navy/52">{feature.text}</p>
              </div>
            </article>
          ))}
        </div>
      </section>

      <section className="bg-navy px-5 py-28 text-white sm:px-8" id="open-source">
        <div className="mx-auto grid max-w-6xl items-center gap-16 lg:grid-cols-2">
          <div className="overflow-hidden rounded-3xl border border-white/10 bg-[#0e1725] shadow-2xl shadow-black/25">
            <div className="flex h-14 items-center justify-between border-b border-white/10 px-6 text-xs">
              <span className="font-mono text-white/70">.robine-ci/workflows/quality.yml</span>
              <span className="rounded-full bg-teal/15 px-2.5 py-1 font-bold text-[#71d0ca]">REVIEWED</span>
            </div>
            <pre className="overflow-x-auto p-7 font-mono text-sm leading-7 text-white/70"><code><span className="text-[#71d0ca]">on:</span> [push, pull_request]{"\n\n"}<span className="text-[#71d0ca]">jobs:</span>{"\n"}  test:{"\n"}    <span className="text-[#71d0ca]">image:</span> elixir:1.20{"\n"}    <span className="text-[#71d0ca]">steps:</span>{"\n"}      - <span className="text-[#71d0ca]">run:</span> mix deps.get{"\n"}      - <span className="text-[#71d0ca]">run:</span> mix test</code></pre>
          </div>
          <div>
            <p className="eyebrow eyebrow-dark">Open by conviction</p>
            <h2 className="mt-7 text-5xl font-semibold leading-[1] tracking-[-.055em] sm:text-6xl">No black boxes.<br /><span className="text-white/35">Ever.</span></h2>
            <p className="mt-7 max-w-xl leading-7 text-white/55">Inspect the code, adapt it to your team, and help shape its direction. Your CI should be as transparent as the software you ship.</p>
            <a className="mt-9 inline-flex h-12 items-center gap-3 rounded-xl bg-white px-6 text-sm font-bold text-navy transition hover:-translate-y-0.5" href="https://github.com" target="_blank" rel="noreferrer">Explore the repository <Arrow /></a>
          </div>
        </div>
      </section>

      <section className="px-5 py-24 sm:px-8" id="get-started">
        <div className="cta-panel relative mx-auto max-w-6xl overflow-hidden rounded-[2rem] border border-teal/20 bg-surface px-6 py-20 text-center shadow-panel sm:px-12">
          <div className="pointer-events-none absolute left-1/2 top-0 size-[32rem] -translate-x-1/2 -translate-y-1/2 rounded-full bg-teal/12 blur-3xl" />
          <div className="relative">
            <p className="eyebrow mx-auto w-fit">Ready when you are</p>
            <h2 className="mt-7 text-5xl font-semibold leading-[1] tracking-[-.06em] sm:text-7xl">Your next pipeline<br /><span className="text-navy/35">starts here.</span></h2>
            <p className="mx-auto mt-6 max-w-xl leading-7 text-navy/55">Install Robine on your infrastructure and ship your first trusted workflow today.</p>
            <a className="btn-primary mt-9 inline-flex h-12 items-center gap-3 rounded-xl bg-teal px-6 font-bold text-white" href="https://github.com" target="_blank" rel="noreferrer">Get started <span aria-hidden="true">→</span></a>
          </div>
        </div>
      </section>

      <footer className="border-t border-line bg-surface px-5 py-8 sm:px-8">
        <div className="mx-auto flex max-w-7xl flex-col items-start justify-between gap-6 sm:flex-row sm:items-center">
          <a href="#top"><Brand /></a>
          <p className="text-sm text-navy/45">Open-source CI/CD, thoughtfully built in Europe.</p>
          <div className="flex gap-6 text-sm font-semibold text-navy/55"><a className="hover:text-navy" href="https://github.com" target="_blank" rel="noreferrer">GitHub</a><a className="hover:text-navy" href="#product">Product</a><a className="hover:text-navy" href="#top">Back to top ↑</a></div>
        </div>
      </footer>
    </main>
  );
}
