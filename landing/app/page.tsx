export default function Home() {
  return (
    <>
      <section className="landing">
        <header className="chrome">
          <a className="pill logo" href="#">
            <span className="logo__mark">agent notch</span>
            <span className="logo__sub">open source, for mac</span>
          </a>
          <nav className="pill nav">
            <a className="nav__link" href="#features">features</a>
            <a className="nav__link" href="#how">how it works</a>
            <a className="nav__link" href="#github">github</a>
            <a className="pill pill--dark nav__cta" href="#download">
              download
            </a>
          </nav>
          <div className="stat-wrap">
            <div className="pill pill--stat">
              <span className="dot" style={{ background: "#22c55e" }} />
              <strong>shipped</strong> free and open source
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
              hold the cursor. say what you want. it watches the screen and
              does the rest. your hands stay free. your machine stays yours.
            </p>
            <div className="cta-row">
              <a className="pill pill--dark" href="#download">
                download for mac
              </a>
              <a className="pill pill--soft" href="#how">
                watch one run →
              </a>
            </div>
          </div>

          <div className="stage" aria-hidden="true">
            <div className="macbook">
              <div className="macbook__screen">
                <div className="macbook__display">
                  <div className="desktop-bg" />

                  <div className="notch">
                    <div className="notch__wave">
                      <span /><span /><span /><span /><span /><span />
                    </div>
                    <span className="notch__label">agent on</span>
                  </div>

                  <div className="transcript">
                    <div className="bubble bubble--user">
                      open figma. share the doc with arshan.
                    </div>
                    <div className="bubble bubble--agent">
                      opening figma. sharing with arshan@.
                    </div>
                  </div>
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
          <div className="section__eyebrow">// the shape of it</div>
          <h2 className="section__title">
            not a chat window.
            <br />
            a <em>quiet</em> agent.
          </h2>
          <p className="section__sub">
            no sidebar. no tab to switch to. a body on your cursor, a mind in
            your notch.
          </p>

          <div className="feature-grid">
            <article className="feature">
              <div className="feature__icon feature__icon--warm">✦</div>
              <h3>a body on your cursor</h3>
              <p>
                a soft sprite rides your real cursor. hold it down to speak.
                let go to send. your voice never leaves the machine.
              </p>
            </article>
            <article className="feature">
              <div className="feature__icon feature__icon--blue">◐</div>
              <h3>a mind in your notch</h3>
              <p>
                the agent lives in the notch. you see what it heard, what it
                is doing, what it finished. always there. never in the way.
              </p>
            </article>
            <article className="feature">
              <div className="feature__icon feature__icon--green">◇</div>
              <h3>real clicks, real keys</h3>
              <p>
                reads the screen first. picks the button. sends the keystroke.
                the same moves you would have made at the trackpad.
              </p>
            </article>
          </div>
        </div>
      </section>

      <section className="section" id="how" style={{ paddingTop: 40 }}>
        <div className="section__inner">
          <div className="section__eyebrow">// one turn</div>
          <h2 className="section__title">
            ask once. <em>watch</em> it land.
          </h2>
          <p className="section__sub">
            four steps. about a second each.
          </p>

          <div className="steps">
            <div className="step">
              <span className="step__num">01 · hold</span>
              <h4>press the cursor</h4>
              <p>
                hold the sprite. it pulses. the mic opens. nothing else on
                screen changes.
              </p>
            </div>
            <div className="step">
              <span className="step__num">02 · speak</span>
              <h4>say the thing</h4>
              <p>
                let go. your voice becomes text on the machine. nothing
                uploaded.
              </p>
            </div>
            <div className="step">
              <span className="step__num">03 · read</span>
              <h4>the agent looks</h4>
              <p>
                reads your last few screens. sees what you saw. knows where
                the buttons are before it moves.
              </p>
            </div>
            <div className="step">
              <span className="step__num">04 · move</span>
              <h4>it actually clicks</h4>
              <p>
                real keystrokes, real clicks. the notch shows what it is
                doing the whole way.
              </p>
            </div>
          </div>
        </div>
      </section>

      <section className="closing" id="download">
        <h2 className="closing__title">
          stop typing. <em>start asking.</em>
        </h2>
        <p className="closing__sub">
          free. open source. yours.
        </p>
        <div className="cta-row">
          <a className="pill pill--dark" href="#">
            download for mac
          </a>
          <a className="pill pill--soft" href="#github">
            star on github
          </a>
        </div>
      </section>

      <footer className="footer">
        <span className="footer__mark">agent notch</span>
        <div className="footer__links">
          <a href="#features">features</a>
          <a href="#how">how it works</a>
          <a href="#github">github</a>
          <span className="footer__license">mit licensed</span>
        </div>
        <span>open source. made with care.</span>
      </footer>
    </>
  );
}
