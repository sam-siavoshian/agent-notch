export default function Home() {
  return (
    <>
      <section className="landing">
        <header className="chrome">
          <a className="pill logo" href="#">
            <span className="logo__mark">agent notch</span>
            <span className="logo__sub">a macOS computer-use agent</span>
          </a>
          <nav className="pill nav">
            <a className="nav__link" href="#features">features</a>
            <a className="nav__link" href="#how">how it works</a>
            <a className="nav__link" href="#stack">stack</a>
            <a className="pill pill--dark nav__cta" href="#download">
              download
            </a>
          </nav>
          <div className="stat-wrap">
            <div className="pill pill--stat">
              <span className="dot" style={{ background: "#22c55e" }} />
              <strong>live</strong> ships in your notch
            </div>
          </div>
        </header>

        <div className="hero">
          <div>
            <h1 className="headline">
              the agent that <em>lives</em>
              <br />
              in your notch.
            </h1>
            <p className="sub">
              long-press the cursor. speak. it sees your screen, reads what
              matters, and clicks for you. nothing leaves your mac you did not
              put there.
            </p>
            <div className="cta-row">
              <a className="pill pill--dark" href="#download">
                download for mac
              </a>
              <a className="pill pill--soft" href="#how">
                see how it works →
              </a>
            </div>
          </div>

          <div className="stage" aria-hidden="true">
            <div className="float-chip pill float-chip--listen">
              <span className="badge">↗</span>
              listening
            </div>
            <div className="float-chip pill float-chip--ctx">
              <span className="badge">i</span>
              reading screen
            </div>
            <div className="float-chip pill float-chip--ok">
              <span className="badge">✓</span>
              clicked submit
            </div>

            <div className="macbook">
              <div className="macbook__screen">
                <div className="macbook__display">
                  <div className="desktop-bg" />
                  <div className="desktop-grain" />

                  <div className="notch">
                    <div className="notch__wave">
                      <span /><span /><span /><span /><span /><span />
                    </div>
                    <span className="notch__label">agent on</span>
                  </div>

                  <div className="desktop-card desktop-card--a">
                    <span className="badge">✓</span> calendar synced
                  </div>
                  <div className="desktop-card desktop-card--b">
                    <span className="badge">↗</span> draft sent
                  </div>
                  <div className="desktop-card desktop-card--c">
                    <span className="badge">i</span> 3 tabs · figma · slack
                  </div>

                  <div className="companion" />
                </div>
              </div>
              <div className="macbook__hinge" />
              <div className="macbook__base" />
            </div>
          </div>
        </div>
      </section>

      <section className="section" id="features">
        <div className="section__inner">
          <div className="section__eyebrow">// surface</div>
          <h2 className="section__title">
            two surfaces.
            <br />
            one <em>quiet</em> agent.
          </h2>
          <p className="section__sub">
            it is not a chat window. it is a body on your cursor and a mind in
            your notch. talk to it like a person. correct it like a colleague.
          </p>

          <div className="feature-grid">
            <article className="feature">
              <div className="feature__icon feature__icon--warm">✦</div>
              <h3>cursor companion</h3>
              <p>
                a soft sprite follows your real cursor. long-press to speak.
                release to dispatch. WhisperKit transcribes on-device, no audio
                leaves the mac.
              </p>
            </article>
            <article className="feature">
              <div className="feature__icon feature__icon--blue">◐</div>
              <h3>notch ui</h3>
              <p>
                the agent lives in the MacBook notch. status, last transcript,
                activity feed. tap to open. swipe to settings. cmd+d to toggle.
              </p>
            </article>
            <article className="feature">
              <div className="feature__icon feature__icon--green">◇</div>
              <h3>computer use</h3>
              <p>
                Claude Sonnet drives CGEvent clicks, keystrokes, and scrolls.
                screen context is summarized by an on-device OCR + Gemini
                pipeline before each turn.
              </p>
            </article>
          </div>
        </div>
      </section>

      <section className="section" id="how" style={{ paddingTop: 40 }}>
        <div className="section__inner">
          <div className="section__eyebrow">// loop</div>
          <h2 className="section__title">
            how one turn <em>actually</em> runs.
          </h2>
          <p className="section__sub">
            four steps. measured in seconds. the same loop we debug in dev
            tools.
          </p>

          <div className="steps">
            <div className="step">
              <span className="step__num">01 · capture</span>
              <h4>long-press the cursor</h4>
              <p>
                a long-press detector posts a notification. the mic opens.
                voice recording starts. the sprite pulses.
              </p>
            </div>
            <div className="step">
              <span className="step__num">02 · transcribe</span>
              <h4>whisperkit on-device</h4>
              <p>
                release ends the recording. WhisperKit transcribes locally.
                .transcriptReady fires the agent session.
              </p>
            </div>
            <div className="step">
              <span className="step__num">03 · context</span>
              <h4>screen + memory packet</h4>
              <p>
                OCR over recent screenshots, Gemini summarizes each, the
                rolling buffer becomes a compact prompt packet.
              </p>
            </div>
            <div className="step">
              <span className="step__num">04 · act</span>
              <h4>sonnet drives the mac</h4>
              <p>
                computer-use tool calls become CGEvents. clicks, keystrokes,
                scrolls. the notch shows live status the whole turn.
              </p>
            </div>
          </div>
        </div>
      </section>

      <section className="section" id="stack" style={{ paddingTop: 40 }}>
        <div className="section__inner">
          <div className="section__eyebrow">// under the hood</div>
          <h2 className="section__title">stack you can read in an afternoon.</h2>
          <p className="section__sub">
            SwiftUI + AppKit. no electron, no web wrappers, no chromium. one
            binary, one process, one notch.
          </p>
          <div className="stack-row">
            <div className="stack-pill"><span>ui</span>SwiftUI · NSPanel</div>
            <div className="stack-pill"><span>agent</span>claude-sonnet-4-6</div>
            <div className="stack-pill"><span>voice</span>WhisperKit</div>
            <div className="stack-pill"><span>vision</span>VisionKit OCR</div>
            <div className="stack-pill"><span>context</span>Gemini 2.5</div>
            <div className="stack-pill"><span>drive</span>CGEventTap</div>
            <div className="stack-pill"><span>build</span>XcodeGen</div>
            <div className="stack-pill"><span>min</span>macOS 14 · M-series</div>
          </div>
        </div>
      </section>

      <section className="closing" id="download">
        <h2 className="closing__title">
          stop typing. <em>start asking.</em>
        </h2>
        <p className="closing__sub">
          one binary, your notch, your screen. accessibility, screen recording
          and microphone, only what the agent actually needs.
        </p>
        <div className="cta-row">
          <a className="pill pill--dark" href="#">
            download for mac
          </a>
          <a className="pill pill--soft" href="#">
            read the prd
          </a>
        </div>
      </section>

      <footer className="footer">
        <span className="footer__mark">agent notch</span>
        <div className="footer__links">
          <a href="#features">features</a>
          <a href="#how">how it works</a>
          <a href="#stack">stack</a>
          <a href="#">github</a>
          <span className="footer__license">mit licensed</span>
        </div>
        <span>built at tritonhacks 2026</span>
      </footer>
    </>
  );
}
