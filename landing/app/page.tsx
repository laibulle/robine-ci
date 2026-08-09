const Check = () => <span aria-hidden="true">✓</span>;

const Arrow = () => <span aria-hidden="true">↗</span>;

const pipelineSteps = [
  { name: "Install", meta: "18s", state: "done" },
  { name: "Tests", meta: "1m 04s", state: "done" },
  { name: "Build", meta: "32s", state: "active" },
  { name: "Deploy", meta: "pending", state: "waiting" },
];

export default function Home() {
  return (
    <main>
      <header className="site-header">
        <a className="brand" href="#top" aria-label="Robine CI, home">
          <span className="brand-mark" aria-hidden="true">R</span>
          <span>ROBINE<span className="brand-muted">/CI</span></span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#product">Product</a>
          <a href="#control">Why Robine</a>
          <a href="#open-source">Open source</a>
        </nav>
        <a className="header-cta" href="#get-started">Get started <Arrow /></a>
      </header>

      <section className="hero" id="top">
        <div className="hero-copy">
          <p className="eyebrow"><span /> SELF-HOSTED CI/CD</p>
          <h1>Your code.<br />Your rules.<br /><em>Your</em> infrastructure.</h1>
          <p className="hero-lede">Fast, readable, sovereign CI. Robine turns every commit into a pipeline you understand — and control.</p>
          <div className="hero-actions">
            <a className="button button-dark" href="#get-started">Install Robine <span>→</span></a>
            <a className="text-link" href="https://github.com" target="_blank" rel="noreferrer">View on GitHub <Arrow /></a>
          </div>
          <p className="install-note"><span aria-hidden="true">⌁</span> Up and running on your infrastructure in under 5 minutes</p>
        </div>

        <div className="hero-visual" aria-label="Preview of a running Robine pipeline">
          <div className="sun" />
          <div className="dot-grid" />
          <div className="pipeline-card">
            <div className="card-bar">
              <div className="traffic"><i /><i /><i /></div>
              <span>feat/auth-passkeys</span>
              <span className="live"><i /> RUNNING</span>
            </div>
            <div className="pipeline-head">
              <div>
                <p>PIPELINE #0248</p>
                <h2>Ready to ship.</h2>
              </div>
              <div className="elapsed"><strong>01:54</strong><span>ELAPSED</span></div>
            </div>
            <div className="steps">
              {pipelineSteps.map((step) => (
                <div className={`step ${step.state}`} key={step.name}>
                  <span className="step-icon">{step.state === "done" ? <Check /> : step.state === "active" ? "↻" : "·"}</span>
                  <span className="step-name">{step.name}</span>
                  <span className="step-meta">{step.meta}</span>
                </div>
              ))}
            </div>
            <div className="terminal">
              <p><span>$</span> mix test</p>
              <p>..............................................</p>
              <p className="terminal-success">128 tests, 0 failures <span>✓</span></p>
              <p className="cursor-line"><span>›</span> Building Docker image <i /></p>
            </div>
            <div className="card-foot"><span><i /> runner-paris-01</span><strong>main@7f2a9c1</strong></div>
          </div>
          <div className="success-stamp"><Check /><span>TESTS<br /><strong>PASSED</strong></span></div>
        </div>
      </section>

      <section className="trust-strip" aria-label="Key benefits">
        <p>BUILT FOR TEAMS THAT<br /><strong>WANT TO STAY IN CONTROL.</strong></p>
        <ul>
          <li><Check /> 100% open source</li>
          <li><Check /> Your data stays with you</li>
          <li><Check /> Isolated Docker runners</li>
        </ul>
      </section>

      <section className="features" id="product">
        <div className="section-intro">
          <p className="eyebrow"><span /> SIMPLE BY DESIGN</p>
          <h2>CI that never<br />slows you <em>down.</em></h2>
          <p>From your first commit to production, Robine stays fast, predictable, and genuinely pleasant to use.</p>
        </div>
        <div className="feature-grid">
          <article>
            <span className="feature-number">01</span>
            <div className="feature-icon bolt" aria-hidden="true">ϟ</div>
            <h3>Actually fast.</h3>
            <p>Smart caching, parallel execution, and runners close to your code. Leave wasted minutes in the past.</p>
            <a href="#get-started" aria-label="Learn more about performance">Discover <Arrow /></a>
          </article>
          <article className="feature-dark" id="control">
            <span className="feature-number">02</span>
            <div className="feature-icon shield" aria-hidden="true">◆</div>
            <h3>On your infrastructure. Really.</h3>
            <p>Your code, secrets, and artifacts never leave your infrastructure. No compromises.</p>
            <a href="#get-started" aria-label="Learn more about self-hosting">Explore <Arrow /></a>
          </article>
          <article>
            <span className="feature-number">03</span>
            <div className="feature-icon lines" aria-hidden="true">≋</div>
            <h3>Clear at every step.</h3>
            <p>Clean logs, explicit statuses, and an interface designed to diagnose failures in seconds.</p>
            <a href="#get-started" aria-label="Learn more about pipelines">View pipelines <Arrow /></a>
          </article>
        </div>
      </section>

      <section className="open-source" id="open-source">
        <div className="code-window" aria-label="Robine workflow example">
          <div className="code-title"><span>robine.yml</span><i>PUBLIC</i></div>
          <pre><code><span className="purple">on:</span> [push, pull_request]{"\n\n"}<span className="purple">jobs:</span>{"\n"}  test:{"\n"}    <span className="purple">image:</span> elixir:1.18{"\n"}    <span className="purple">steps:</span>{"\n"}      - <span className="purple">run:</span> mix deps.get{"\n"}      - <span className="purple">run:</span> mix test</code></pre>
        </div>
        <div className="source-copy">
          <p className="eyebrow light"><span /> OPEN BY CONVICTION</p>
          <h2>No black boxes.<br /><em>Ever.</em></h2>
          <p>Robine is open source from end to end. Inspect the code, adapt it to your team, and help shape its direction. Your CI should be as transparent as your code.</p>
          <a className="button button-light" href="https://github.com" target="_blank" rel="noreferrer">Explore the repository <Arrow /></a>
        </div>
      </section>

      <section className="final-cta" id="get-started">
        <div className="cta-orb" />
        <p className="eyebrow"><span /> READY TO TAKE BACK CONTROL?</p>
        <h2>Your next pipeline<br />starts <em>here.</em></h2>
        <p>Install Robine on your infrastructure and run your first pipeline today.</p>
        <a className="button button-dark" href="https://github.com" target="_blank" rel="noreferrer">Get started now <span>→</span></a>
      </section>

      <footer>
        <a className="brand" href="#top"><span className="brand-mark">R</span><span>ROBINE<span className="brand-muted">/CI</span></span></a>
        <p>Open-source CI/CD, thoughtfully built in Europe.</p>
        <div><a href="https://github.com" target="_blank" rel="noreferrer">GitHub</a><a href="#product">Documentation</a><a href="#top">Back to top ↑</a></div>
      </footer>
    </main>
  );
}
