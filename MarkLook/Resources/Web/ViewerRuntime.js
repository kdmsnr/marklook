(() => {
  "use strict";

  const state = {
    host: null,
    root: null,
    content: null,
    generation: 0,
    firstRender: true,
    interactionVersion: 0,
    contentWidth: 1200,
    contentWidthRevision: 0,
    requestedContentWidth: 1200,
    requestedContentWidthRevision: 0,
    layoutVersion: 0,
    layoutGate: Promise.resolve(),
    activeLayoutReaders: 0,
    layoutReadersIdle: Promise.resolve(),
    resolveLayoutReadersIdle: null,
    exclusiveLayoutChangeActive: false,
    exclusiveLayoutChangeIdle: Promise.resolve(),
    resolveExclusiveLayoutChangeIdle: null,
    mathCache: new Map(),
    highlightCache: new Map(),
  };

  const nextFrame = () => new Promise(resolve => requestAnimationFrame(() => resolve()));

  async function withLayoutGate(operation) {
    const previous = state.layoutGate;
    let release;
    state.layoutGate = new Promise(resolve => { release = resolve; });
    await previous;
    try {
      return await operation();
    } finally {
      release();
    }
  }

  async function beginLayoutRead() {
    await withLayoutGate(async () => {
      if (state.exclusiveLayoutChangeActive) await state.exclusiveLayoutChangeIdle;
      if (state.activeLayoutReaders === 0) {
        state.layoutReadersIdle = new Promise(resolve => {
          state.resolveLayoutReadersIdle = resolve;
        });
      }
      state.activeLayoutReaders += 1;
    });
  }

  function endLayoutRead() {
    state.activeLayoutReaders = Math.max(0, state.activeLayoutReaders - 1);
    if (state.activeLayoutReaders !== 0) return;
    const resolve = state.resolveLayoutReadersIdle;
    state.resolveLayoutReadersIdle = null;
    resolve?.();
  }

  async function beginExclusiveLayoutChange() {
    await withLayoutGate(async () => {
      if (state.exclusiveLayoutChangeActive) await state.exclusiveLayoutChangeIdle;
      if (state.activeLayoutReaders > 0) await state.layoutReadersIdle;
      state.exclusiveLayoutChangeActive = true;
      state.exclusiveLayoutChangeIdle = new Promise(resolve => {
        state.resolveExclusiveLayoutChangeIdle = resolve;
      });
    });
  }

  function endExclusiveLayoutChange() {
    state.exclusiveLayoutChangeActive = false;
    const resolve = state.resolveExclusiveLayoutChangeIdle;
    state.resolveExclusiveLayoutChangeIdle = null;
    resolve?.();
  }

  function normalizedContentWidth(value) {
    if (value === null) return null;
    const number = Number(value);
    if (!Number.isFinite(number) || number <= 0) return state.contentWidth;
    return Math.min(Math.max(number, 480), 2400);
  }

  function applyContentWidth(value, revision) {
    const numericRevision = Number(revision);
    const newestRevision = Math.max(
      state.contentWidthRevision,
      state.requestedContentWidthRevision
    );
    if (Number.isFinite(numericRevision) && numericRevision < newestRevision) return false;
    if (Number.isFinite(numericRevision)) state.contentWidthRevision = numericRevision;
    state.contentWidth = normalizedContentWidth(value);
    if (state.host) {
      state.host.style.setProperty(
        "--marklook-content-width",
        state.contentWidth === null ? "none" : `${state.contentWidth}px`
      );
    }
    return true;
  }

  function cacheValue(cache, key, value, limit) {
    if (cache.has(key)) cache.delete(key);
    cache.set(key, value);
    while (cache.size > limit) cache.delete(cache.keys().next().value);
  }

  function ensureRoot(baseCSS, katexCSS, highlightCSS) {
    if (state.root) return;
    state.host = document.getElementById("content-host");
    state.root = state.host.attachShadow({ mode: "open" });

    const style = document.createElement("style");
    style.textContent = [baseCSS, katexCSS, highlightCSS].join("\n");
    const content = document.createElement("article");
    content.id = "document-content";
    content.setAttribute("role", "document");
    state.root.append(style, content);
    state.content = content;
    applyContentWidth(state.contentWidth, state.contentWidthRevision);

    for (const eventName of ["wheel", "mousedown", "keydown", "touchstart"]) {
      window.addEventListener(eventName, event => {
        if (event.isTrusted) state.interactionVersion += 1;
      }, { passive: true, capture: true });
    }
    window.addEventListener("scroll", event => {
      if (event.isTrusted) state.interactionVersion += 1;
    }, { passive: true });
  }

  function captureScroll() {
    const scrollElement = document.scrollingElement || document.documentElement;
    const maximum = Math.max(0, scrollElement.scrollHeight - scrollElement.clientHeight);
    const candidates = [...state.content.querySelectorAll("[data-marklook-anchor]")];
    let anchor = null;
    let offset = 0;
    for (const element of candidates) {
      const rect = element.getBoundingClientRect();
      if (rect.bottom >= 0) {
        anchor = element.getAttribute("data-marklook-anchor");
        offset = rect.top;
        break;
      }
    }
    return {
      anchor,
      offset,
      ratio: maximum > 0 ? scrollElement.scrollTop / maximum : 0,
      atBottom: maximum - scrollElement.scrollTop <= 24,
      fragment: location.hash ? decodeURIComponent(location.hash.slice(1)) : null,
    };
  }

  function captureCalloutDisclosureState() {
    const disclosureState = new Map();
    for (const callout of state.content.querySelectorAll("details.callout[data-marklook-anchor]")) {
      const anchor = callout.getAttribute("data-marklook-anchor");
      if (anchor !== null && !disclosureState.has(anchor)) {
        disclosureState.set(anchor, callout.open);
      }
    }
    return disclosureState;
  }

  function restoreCalloutDisclosureState(disclosureState) {
    for (const callout of state.content.querySelectorAll("details.callout[data-marklook-anchor]")) {
      const anchor = callout.getAttribute("data-marklook-anchor");
      if (anchor !== null && disclosureState.has(anchor)) {
        callout.open = disclosureState.get(anchor);
      }
    }
  }

  function syncAttributes(current, incoming) {
    for (const attribute of [...current.attributes]) {
      if (!incoming.hasAttribute(attribute.name)) current.removeAttribute(attribute.name);
    }
    for (const attribute of [...incoming.attributes]) {
      if (current.getAttribute(attribute.name) !== attribute.value) {
        current.setAttribute(attribute.name, attribute.value);
      }
    }
  }

  function morphNode(current, incoming) {
    if (!current || current.nodeType !== incoming.nodeType || current.nodeName !== incoming.nodeName) {
      current?.replaceWith(incoming.cloneNode(true));
      return;
    }
    if (current.nodeType === Node.TEXT_NODE) {
      if (current.nodeValue !== incoming.nodeValue) current.nodeValue = incoming.nodeValue;
      return;
    }
    if (!(current instanceof Element) || !(incoming instanceof Element)) return;
    syncAttributes(current, incoming);
    const incomingChildren = [...incoming.childNodes];
    for (let index = 0; index < incomingChildren.length; index += 1) {
      const oldChild = current.childNodes[index];
      const newChild = incomingChildren[index];
      if (!oldChild) {
        current.append(newChild.cloneNode(true));
      } else {
        morphNode(oldChild, newChild);
      }
    }
    while (current.childNodes.length > incomingChildren.length) {
      current.lastChild?.remove();
    }
  }

  function patchContent(fragment, useFineDiff) {
    const disclosureState = state.firstRender
      ? new Map()
      : captureCalloutDisclosureState();
    const template = document.createElement("template");
    template.innerHTML = fragment;
    if (!useFineDiff || state.firstRender) {
      state.content.replaceChildren(template.content.cloneNode(true));
      restoreCalloutDisclosureState(disclosureState);
      return;
    }

    const incoming = [...template.content.childNodes];
    for (let index = 0; index < incoming.length; index += 1) {
      const oldNode = state.content.childNodes[index];
      const newNode = incoming[index];
      if (!oldNode) state.content.append(newNode.cloneNode(true));
      else morphNode(oldNode, newNode);
    }
    while (state.content.childNodes.length > incoming.length) {
      state.content.lastChild?.remove();
    }
    restoreCalloutDisclosureState(disclosureState);
  }

  function renderMath() {
    const warnings = [];
    const renderer = globalThis.katex;
    for (const element of state.content.querySelectorAll("[data-marklook-math]")) {
      const source = element.textContent || "";
      const displayMode = element.getAttribute("data-display") === "block";
      const cacheKey = `${displayMode ? "b" : "i"}\u0000${source}`;
      try {
        let rendered = state.mathCache.get(cacheKey);
        if (!rendered) {
          if (!renderer || typeof renderer.renderToString !== "function") throw new Error("KaTeX is unavailable");
          rendered = renderer.renderToString(source, {
            displayMode,
            throwOnError: true,
            strict: "warn",
            trust: false,
            output: "htmlAndMathml",
          });
          cacheValue(state.mathCache, cacheKey, rendered, 256);
        }
        element.innerHTML = rendered;
      } catch (error) {
        element.textContent = source;
        element.classList.add("marklook-math-error");
        warnings.push(`Math: ${error?.message || String(error)}`);
      }
    }
    return warnings;
  }

  function highlightCode(enabled) {
    if (!enabled || !globalThis.hljs) return;
    for (const element of state.content.querySelectorAll("pre > code[class^='language-']")) {
      const languageClass = [...element.classList].find(item => item.startsWith("language-"));
      const language = languageClass?.slice("language-".length);
      if (!language || !globalThis.hljs.getLanguage(language)) continue;
      const source = element.textContent || "";
      const key = `${language}\u0000${source}`;
      let rendered = state.highlightCache.get(key);
      if (!rendered) {
        rendered = globalThis.hljs.highlight(source, { language, ignoreIllegals: true }).value;
        cacheValue(state.highlightCache, key, rendered, 128);
      }
      element.innerHTML = rendered;
      element.classList.add("hljs");
    }
  }

  function elementForAnchor(anchor) {
    if (!anchor) return null;
    const escaped = CSS.escape(anchor);
    return state.root.getElementById(anchor) || state.content.querySelector(`[data-marklook-anchor="${escaped}"]`);
  }

  function restoreScroll(snapshot, explicitAnchor) {
    const scrollElement = document.scrollingElement || document.documentElement;
    const requested = elementForAnchor(explicitAnchor || snapshot.fragment);
    if (requested) {
      requested.scrollIntoView({ block: "start" });
      return;
    }
    if (snapshot.atBottom) {
      scrollElement.scrollTop = scrollElement.scrollHeight;
      return;
    }
    const anchor = elementForAnchor(snapshot.anchor);
    if (anchor) {
      window.scrollBy(0, anchor.getBoundingClientRect().top - snapshot.offset);
      return;
    }
    const maximum = Math.max(0, scrollElement.scrollHeight - scrollElement.clientHeight);
    scrollElement.scrollTop = maximum * snapshot.ratio;
  }

  async function settleLayout(snapshot, explicitAnchor, generation, interactionVersion, layoutVersion) {
    const images = [...state.content.querySelectorAll("img")];
    const imageWork = images.map(image => image.complete ? Promise.resolve() : image.decode?.().catch(() => undefined));
    const fontWork = document.fonts?.ready || Promise.resolve();
    await Promise.race([
      Promise.allSettled([...imageWork, fontWork]),
      new Promise(resolve => setTimeout(resolve, 350)),
    ]);
    if (state.generation !== generation
        || state.interactionVersion !== interactionVersion
        || state.layoutVersion !== layoutVersion) return;
    restoreScroll(snapshot, explicitAnchor);
  }

  globalThis.marklookRuntime = {
    async applyUpdate(argumentsObject) {
      await beginLayoutRead();
      try {
        const started = performance.now();
        ensureRoot(argumentsObject.baseCSS || "", argumentsObject.katexCSS || "", argumentsObject.highlightCSS || "");
        // Native presentation generations are unique for this WebView's entire lifetime, including
        // same-tab navigation that replaces the file scheduler. Reject equal values as replays too.
        if (argumentsObject.generation <= state.generation) return { stale: true, warnings: [] };
        state.generation = argumentsObject.generation;
        state.layoutVersion += 1;
        const layoutVersion = state.layoutVersion;
        const snapshot = state.firstRender
          ? { anchor: null, offset: 0, ratio: 0, atBottom: false, fragment: null }
          : captureScroll();
        const interactionVersion = state.interactionVersion;

        if (!applyContentWidth(argumentsObject.contentWidth, argumentsObject.contentWidthRevision)) {
          applyContentWidth(
            state.requestedContentWidth,
            state.requestedContentWidthRevision
          );
        }
        patchContent(argumentsObject.html || "", Boolean(argumentsObject.useFineDiff));
        state.content.classList.toggle("marklook-lightweight", !argumentsObject.useFineDiff);
        const warnings = argumentsObject.containsMath ? renderMath() : [];
        highlightCode(Boolean(argumentsObject.highlight));
        await nextFrame();
        if (argumentsObject.generation !== state.generation) return { stale: true, warnings: [] };
        if (state.interactionVersion === interactionVersion && state.layoutVersion === layoutVersion) {
          restoreScroll(snapshot, argumentsObject.explicitAnchor || null);
        }
        await nextFrame();
        if (argumentsObject.generation !== state.generation) return { stale: true, warnings: [] };

        state.host.style.visibility = "visible";
        state.firstRender = false;
        void settleLayout(
          snapshot,
          argumentsObject.explicitAnchor || null,
          state.generation,
          interactionVersion,
          layoutVersion
        );
        return { stale: false, warnings, durationMS: performance.now() - started };
      } finally {
        endLayoutRead();
      }
    },

    async setContentWidth(width, revision) {
      const numericRevision = Number(revision);
      if (Number.isFinite(numericRevision)) {
        if (numericRevision < state.requestedContentWidthRevision) return false;
        state.requestedContentWidthRevision = numericRevision;
        state.requestedContentWidth = normalizedContentWidth(width);
      }

      await beginExclusiveLayoutChange();
      try {
        if (Number.isFinite(numericRevision)
            && numericRevision < state.requestedContentWidthRevision) return false;

        const targetWidth = Number.isFinite(numericRevision)
          ? state.requestedContentWidth
          : normalizedContentWidth(width);
        const targetRevision = Number.isFinite(numericRevision)
          ? state.requestedContentWidthRevision
          : revision;
        if (targetRevision <= state.contentWidthRevision && targetWidth === state.contentWidth) {
          return true;
        }

        const snapshot = state.content && !state.firstRender
          ? { ...captureScroll(), fragment: null }
          : null;
        const interactionVersion = state.interactionVersion;
        if (!applyContentWidth(targetWidth, targetRevision)) return false;
        const layoutVersion = ++state.layoutVersion;
        if (!snapshot) return true;

        await nextFrame();
        if (layoutVersion !== state.layoutVersion || state.interactionVersion !== interactionVersion) return false;
        restoreScroll(snapshot, null);
        return true;
      } finally {
        endExclusiveLayoutChange();
      }
    },

    navigateAnchor(anchor) {
      ensureRoot("", "", "");
      const element = elementForAnchor(anchor);
      if (!element) return false;
      element.scrollIntoView({ block: "start" });
      history.replaceState(null, "", `#${encodeURIComponent(anchor)}`);
      return true;
    },

    async invalidateResources(sources, revision) {
      await beginExclusiveLayoutChange();
      try {
        ensureRoot("", "", "");
        const snapshot = captureScroll();
        const interactionVersion = state.interactionVersion;
        const layoutVersion = ++state.layoutVersion;
        const wanted = new Set(sources || []);
        for (const element of state.content.querySelectorAll("[src], link[href]")) {
          const attribute = element.hasAttribute("src") ? "src" : "href";
          const url = new URL(element.getAttribute(attribute), location.href);
          if (!wanted.has(url.searchParams.get("source"))) continue;
          url.searchParams.set("revision", String(revision));
          element.setAttribute(attribute, url.toString());
        }
        await nextFrame();
        if (state.interactionVersion === interactionVersion && state.layoutVersion === layoutVersion) {
          restoreScroll(snapshot, null);
        }
        void settleLayout(snapshot, null, state.generation, interactionVersion, layoutVersion);
      } finally {
        endExclusiveLayoutChange();
      }
    },

    find(query, backwards) {
      if (!query) {
        getSelection()?.removeAllRanges();
        return false;
      }
      return window.find(query, false, Boolean(backwards), true, false, true, false);
    },

    scrollState() {
      if (!state.content) return null;
      return captureScroll();
    },

    async restoreScrollState(snapshot) {
      await beginExclusiveLayoutChange();
      try {
        ensureRoot("", "", "");
        state.layoutVersion += 1;
        restoreScroll(
          snapshot || { anchor: null, offset: 0, ratio: 0, atBottom: false, fragment: null },
          null
        );
      } finally {
        endExclusiveLayoutChange();
      }
    },
  };
})();
