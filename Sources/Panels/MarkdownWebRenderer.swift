import AppKit
import SwiftUI
import WebKit

struct MarkdownWebRenderer: NSViewRepresentable {
    static let localImageURLScheme = "cmux-local-image"
    static let remoteImageURLScheme = "cmux-remote-image"

    let markdown: String
    let theme: MarkdownWebTheme
    let backgroundColor: NSColor
    let panelId: UUID
    let workspaceId: UUID
    let filePath: String
    /// Body font size in points, applied as `pageZoom` and to shell-managed SVG zoom.
    let fontSize: Double
    /// Body prose font-family name (empty = System). Applied as an inline
    /// `font-family` on the content.
    let fontFamily: String
    /// Maximum content column width, in CSS pixels.
    let maxContentWidth: Double
    let session: MarkdownRendererSession
    /// Whether this renderer is the layer actually shown (tab selected in its
    /// pane, preview mode). Drives the orphaned-webview watchdog: a *visible*
    /// panel whose webview has no window is a hosting failure, whereas a
    /// hidden tab's webview legitimately leaves the window (SwiftUI culls
    /// zero-opacity platform views).
    let isVisibleInUI: Bool
    /// Asks the hosting SwiftUI view to rebuild this representable (bump its
    /// `.id`), which re-runs `makeNSView` and re-adopts the session-retained
    /// webview into a live host. The recovery for an orphaned webview.
    let onRequestRehost: () -> Void
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        session.coordinator(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
    }

    /// Each representable instance gets its own throwaway container view; the
    /// shared, session-retained WKWebView is parented into the *current*
    /// container by the coordinator (the single owner of webview parenting).
    ///
    /// Why not return the WKWebView directly: SwiftUI can host two
    /// representable instances for the same tab within one transaction (e.g. a
    /// cross-pane move whose source pane collapses). If both hosts hand SwiftUI
    /// the same NSView instance, the dying host's teardown rips the webview out
    /// of the adopting host's hierarchy — permanently, since SwiftUI believes
    /// the new host still holds it. With per-host containers, teardown only
    /// ever destroys a container; the coordinator re-parents the webview into
    /// the live container on the next runloop tick.
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true
        ensureWebView(context: context)
        context.coordinator.adopt(container: container)
        return container
    }

    /// Create the session-retained webview if needed, and (re)apply the
    /// per-host bindings that must track the current renderer instance.
    private func ensureWebView(context: Context) {
        if let webView = context.coordinator.webView {
            webView.onPointerDown = onRequestPanelFocus
            webView.onLeaveWindow = { [weak coordinator = context.coordinator] in
                coordinator?.handleViewLeftWindow()
            }
            webView.onReenterWindow = { [weak coordinator = context.coordinator] in
                coordinator?.handleViewReenteredWindow()
            }
            webView.navigationDelegate = context.coordinator
            webView.uiDelegate = context.coordinator
            applyBackground(to: webView)
            applyAppearance(to: webView, isDark: theme.isDark)
            context.coordinator.setFontSize(fontSize)
            context.coordinator.setFontFamily(fontFamily)
            context.coordinator.setMaxContentWidth(maxContentWidth)
            return
        }

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // Bridge: JS posts to `cmuxLib` to request lazy-loaded libraries
        // (mermaid / vega-lite). Swift fetches the bundled source from the
        // app bundle and injects it via evaluateJavaScript.
        config.userContentController.add(WeakMarkdownScriptMessageHandler(context.coordinator), name: "cmuxLib")
        config.setURLSchemeHandler(
            context.coordinator,
            forURLScheme: Self.localImageURLScheme
        )
        config.setURLSchemeHandler(
            context.coordinator,
            forURLScheme: Self.remoteImageURLScheme
        )
        let webView = MarkdownWebView(frame: .zero, configuration: config)
        webView.onPointerDown = onRequestPanelFocus
        webView.onLeaveWindow = { [weak coordinator = context.coordinator] in
            coordinator?.handleViewLeftWindow()
        }
        webView.onReenterWindow = { [weak coordinator = context.coordinator] in
            coordinator?.handleViewReenteredWindow()
        }
        webView.setValue(false, forKey: "drawsBackground")
        applyBackground(to: webView)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        applyAppearance(to: webView, isDark: theme.isDark)

        context.coordinator.webView = webView
        context.coordinator.setFontSize(fontSize)
        context.coordinator.setFontFamily(fontFamily)
        context.coordinator.setMaxContentWidth(maxContentWidth)
        context.coordinator.loadShell(theme: theme, initialMarkdown: markdown)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-bind panel metadata in case SwiftUI recreated the wrapper while
        // the panel-owned renderer session kept the same coordinator.
        context.coordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        context.coordinator.adopt(container: nsView)
        if let webView = context.coordinator.webView {
            (webView as? MarkdownWebView)?.onPointerDown = onRequestPanelFocus
            applyBackground(to: webView)
            applyAppearance(to: webView, isDark: theme.isDark)
        }
        context.coordinator.setFontSize(fontSize)
        context.coordinator.setFontFamily(fontFamily)
        context.coordinator.setMaxContentWidth(maxContentWidth)
        context.coordinator.update(markdown: markdown, theme: theme)
        context.coordinator.onRequestRehost = onRequestRehost
        context.coordinator.setVisible(isVisibleInUI)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.containerWillDismantle(nsView)
        // Legacy path (kept for tests and defense): a raw webview handed in
        // directly — clean it up unless it is the session-retained one.
        guard let webView = nsView as? WKWebView else { return }
        if let retainedWebView = coordinator.webView, retainedWebView === webView {
            return
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        (webView as? MarkdownWebView)?.onPointerDown = nil
        (webView as? MarkdownWebView)?.onLeaveWindow = nil
        (webView as? MarkdownWebView)?.onReenterWindow = nil
        coordinator.cancelImageLoads()
    }

    /// WebKit's `prefers-color-scheme` media query reflects the WKWebView's
    /// effective NSAppearance. Forcing it here lets us decouple the markdown
    /// panel from the system appearance and follow the cmux color scheme.
    private func applyAppearance(to webView: WKWebView, isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        var webView: MarkdownWebView?
        var panelId: UUID = UUID()
        var workspaceId: UUID = UUID()
        var filePath: String = ""
        private var pendingMarkdown: String = ""
        private var pendingTheme: MarkdownWebTheme = .resolve(backgroundColor: GhosttyBackgroundTheme.currentColor())
        private var lastMarkdown: String? = nil
        private var lastTheme: MarkdownWebTheme? = nil
        private var lastFontFamily: String = ""
        private var lastFontSize: Double = MarkdownFontSizeSettings.defaultPointSize
        private var lastMaxContentWidth: Double = MarkdownMaxWidthSettings.defaultCSSPixels
        private var isLoaded = false
        private var isShellLoading = false
        private var webContentProcessRecoveryAttempts = 0
        private let maxWebContentProcessRecoveryAttempts = 2
        /// Whether the shell was confirmed loaded at the moment the host view
        /// last left its window. Used to distinguish a blank state caused by
        /// detaching the pane (WebKit suspending/reclaiming the detached view —
        /// recoverable) from one caused by a payload that keeps crashing
        /// WebContent while attached (a crash loop whose recovery budget must
        /// not be reset by pane reparenting).
        private var shellWasHealthyWhenDetached = false
        /// Whether a shell load was genuinely in flight (not an exhausted
        /// crash loop) at the moment the host view last left its window. A
        /// surface reparented mid-load — e.g. opened and immediately moved
        /// into another pane — was never "healthy", so without this the
        /// re-entry recovery skips it and the panel stays permanently blank.
        private var shellWasLoadingWhenDetached = false

        private struct ImageLoadResult {
            let data: Data
            let mimeType: String
        }

        private final class ImageLoad {
            var reader: Task<ImageLoadResult, Never>?
            var sender: Task<Void, Never>?

            func cancel() {
                reader?.cancel()
                sender?.cancel()
            }
        }
        private var imageLoads: [ObjectIdentifier: ImageLoad] = [:]

#if DEBUG
        var isShellLoadingForTesting: Bool {
            isShellLoading
        }

        var webContentProcessRecoveryAttemptsForTesting: Int {
            webContentProcessRecoveryAttempts
        }
#endif

        func bind(panelId: UUID, workspaceId: UUID, filePath: String) {
            self.panelId = panelId
            self.workspaceId = workspaceId
            self.filePath = filePath
        }

        /// Records the desired body font size and applies it as `pageZoom`.
        /// Stored so it can be re-applied after the shell reloads (e.g. after a
        /// web-content-process crash recovery).
        func setFontSize(_ pointSize: Double) {
            lastFontSize = pointSize
            applyFontSize()
        }

        private func applyFontSize(forceShellSync: Bool = false) {
            guard let webView else { return }
            let zoom = MarkdownFontSizeSettings.pageZoom(forPointSize: lastFontSize)
            let shouldSyncShell = forceShellSync || abs(webView.pageZoom - zoom) > 0.0001
            if abs(webView.pageZoom - zoom) > 0.0001 { webView.pageZoom = zoom }
            if shouldSyncShell { webView.evaluateJavaScript("window.__cmuxSetMarkdownZoom && window.__cmuxSetMarkdownZoom(\(Double(zoom)));", completionHandler: nil) }
        }

        /// Records the desired body prose font and applies it as an inline
        /// `font-family` on the content element. Unlike `pageZoom`, this DOM
        /// style is lost when the shell reloads, so it must be re-applied in
        /// `didFinish`.
        func setFontFamily(_ family: String) {
            lastFontFamily = family
            applyFontFamily()
        }

        private func applyFontFamily() {
            guard let webView else { return }
            // JSON-encode the CSS value (empty string clears the override).
            let css = MarkdownFontFamily.cssValue(for: lastFontFamily) ?? ""
            let encoded = (try? JSONSerialization.data(withJSONObject: [css]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let js = """
            (function(arr) {
              var content = document.getElementById('content');
              if (content) { content.style.fontFamily = arr[0]; }
            })(\(encoded));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Records the desired content column max width. This DOM style is lost
        /// when the shell reloads, so it is re-applied in `didFinish`.
        func setMaxContentWidth(_ pixels: Double) {
            lastMaxContentWidth = MarkdownMaxWidthSettings.clamp(pixels)
            applyMaxContentWidth()
        }

        private func applyMaxContentWidth() {
            guard let webView else { return }
            let width = Int(MarkdownMaxWidthSettings.clamp(lastMaxContentWidth).rounded())
            let js = """
            (function(width) {
              var content = document.getElementById('content');
              if (content) { content.style.maxWidth = width + 'px'; }
            })(\(width));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func close() {
            if let webView {
                webView.stopLoading()
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
                webView.onPointerDown = nil
                webView.onLeaveWindow = nil
                webView.onReenterWindow = nil
            }
            self.webView = nil
            isLoaded = false
            isShellLoading = false
            webContentProcessRecoveryAttempts = 0
            shellWasHealthyWhenDetached = false
            shellWasLoadingWhenDetached = false
            lastVisible = nil
            rehostAttempts = 0
            onRequestRehost = nil
            currentContainer = nil
            cancelImageLoads()
            requestedLibs.removeAll()
        }

        /// Incremented per loadShell so a stalled-load watchdog can tell
        /// whether the load it was armed for is still the current one.
        private var loadGeneration = 0
        /// Set by the hosting view; rebuilds the representable so makeNSView
        /// re-adopts the webview into a live host (orphan recovery).
        var onRequestRehost: (() -> Void)?
        /// The representable container that should currently host the webview.
        /// The coordinator is the single owner of webview parenting — SwiftUI
        /// only ever creates/destroys containers (see makeNSView).
        private weak var currentContainer: NSView?

        /// Make `container` the webview's host. First-time adoption (webview
        /// has no superview) is synchronous so the initial mount never shows a
        /// blank frame. Migration between containers is deferred one runloop
        /// tick: within a single SwiftUI transaction an old host's teardown can
        /// run *after* a new host's creation, so re-parenting immediately would
        /// let the teardown rip the webview back out. After the transaction
        /// settles, the surviving container is unambiguous.
        func adopt(container: NSView) {
            guard currentContainer !== container else {
                scheduleReparentIfNeeded()
                return
            }
            currentContainer = container
            if webView?.superview == nil {
                reparentNow()
            } else {
                scheduleReparentIfNeeded()
            }
        }

        func containerWillDismantle(_ container: NSView) {
            // The webview may sit inside the dying container; make sure a
            // settle-tick re-parent is queued so it lands back in the live one.
            scheduleReparentIfNeeded()
        }

        private var reparentScheduled = false
        private func scheduleReparentIfNeeded() {
            guard !reparentScheduled else { return }
            reparentScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reparentScheduled = false
                self.reparentNow()
            }
        }

        private func reparentNow() {
            guard let webView, let container = currentContainer else { return }
            guard webView.superview !== container else { return }
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
        /// Last shown-state reported by the hosting view.
        private var lastVisible: Bool? = nil
        /// Rehost attempts for the current orphan episode; reset when the
        /// webview is observed back in a window. Caps SwiftUI-rebuild requests
        /// so a pathological hosting failure cannot loop forever.
        private var rehostAttempts = 0
        private let maxRehostAttempts = 3

        /// Reported from `updateNSView`. On a hidden→shown transition, arm the
        /// orphan watchdog: if the webview still has no window shortly after
        /// becoming the visible layer, hosting failed and we request a rehost.
        func setVisible(_ visible: Bool) {
            defer { lastVisible = visible }
            guard visible, lastVisible != true else { return }
            armOrphanWatchdog(delay: 0.7)
        }

        /// A *visible* markdown panel whose webview is not in any window is a
        /// hosting failure. It happens when a surface is moved between panes
        /// (mdtab's open-then-move, manual drags): the collapsing source pane
        /// and the adopting destination pane race, and the session-retained
        /// webview can end up outside the hierarchy with `viewDidMoveToWindow`
        /// never firing again — so no window-event-based recovery can see it.
        /// SwiftUI's own updates won't re-add it either (the host believes it
        /// is already hosting the view). The only repair is to rebuild the
        /// representable via `onRequestRehost` so `makeNSView` re-adopts the
        /// webview — the programmatic equivalent of the "drag the tab to
        /// another pane" folk fix.
        private func armOrphanWatchdog(delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let webView = self.webView else { return }
                guard self.lastVisible == true else { return }
                if webView.window != nil {
                    self.rehostAttempts = 0
                    return
                }
                // First try the cheap repair: put the webview back into the
                // current container (covers a teardown that ripped it out).
                self.reparentNow()
                if webView.window != nil {
                    self.rehostAttempts = 0
                    return
                }
                guard self.rehostAttempts < self.maxRehostAttempts else { return }
                self.rehostAttempts += 1
#if DEBUG
                NSLog("MarkdownPanel.orphanWatchdog rehost attempt=\(self.rehostAttempts) filePath=\(self.filePath)")
#endif
                self.onRequestRehost?()
                // Re-check: either the rehost landed (window != nil resets the
                // counter) or we escalate up to the attempt cap.
                self.armOrphanWatchdog(delay: 1.0)
            }
        }

        func loadShell(theme: MarkdownWebTheme, initialMarkdown: String) {
            pendingMarkdown = initialMarkdown
            pendingTheme = theme
            lastTheme = theme
            requestedLibs.removeAll()
            isLoaded = false
            isShellLoading = true
            loadGeneration += 1
            let html = MarkdownViewerAssets.shared.shellHTML(isDark: theme.isDark)
            let baseURL = URL(fileURLWithPath: filePath)
#if DEBUG
            NSLog("MarkdownPanel.loadShell filePath=\(filePath) baseURL=\(baseURL.absoluteString) htmlBytes=\(html.utf8.count)")
#endif
            webView?.loadHTMLString(html, baseURL: baseURL)
            armStalledLoadWatchdog(generation: loadGeneration, attempt: 0)
        }

        /// A shell load can die silently when its view is reparented mid-load:
        /// the surface is moved to another pane, the collapsing split tears the
        /// old host down, and the retained webview can end up outside any
        /// window with `didFinish` never arriving — and, in the worst case,
        /// `viewDidMoveToWindow` never firing again, so the re-entry recovery
        /// path cannot see it. This watchdog is the recovery of last resort:
        /// it polls after a load starts and, if the load is still not finished,
        /// reloads once the view is back in a window (a reload while detached
        /// would just stall again).
        private func armStalledLoadWatchdog(generation: Int, attempt: Int) {
            let maxAttempts = 5
            guard attempt < maxAttempts else { return }
#if DEBUG
            NSLog("MarkdownPanel.stalledLoadWatchdog armed gen=\(generation) attempt=\(attempt) filePath=\(filePath)")
#endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
#if DEBUG
                NSLog("MarkdownPanel.stalledLoadWatchdog check gen=\(generation) attempt=\(attempt) self=\(self != nil ? 1 : 0) curGen=\(self?.loadGeneration ?? -1) isLoaded=\(String(describing: self?.isLoaded)) isShellLoading=\(String(describing: self?.isShellLoading)) webView=\(self?.webView != nil ? 1 : 0) window=\(self?.webView?.window != nil ? 1 : 0) filePath=\(self?.filePath ?? "?")")
#endif
                guard let self,
                      self.loadGeneration == generation,
                      !self.isLoaded,
                      // Only a load still (nominally) in flight is a stall. A
                      // crash is handled by webViewWebContentProcessDidTerminate,
                      // which clears isShellLoading — so an exhausted crash-loop
                      // budget can never be relaunched from here.
                      self.isShellLoading,
                      let webView = self.webView else { return }
                guard webView.window != nil else {
                    // Not in a window: a reload can't complete. Keep watching —
                    // if the view is ever re-hosted we recover then.
#if DEBUG
                    NSLog("MarkdownPanel.stalledLoadWatchdog gen=\(generation) attempt=\(attempt) detached, rescheduling filePath=\(self.filePath)")
#endif
                    self.armStalledLoadWatchdog(generation: generation, attempt: attempt + 1)
                    return
                }
#if DEBUG
                NSLog("MarkdownPanel.stalledLoadWatchdog gen=\(generation) attempt=\(attempt) reloading stalled shell filePath=\(self.filePath)")
#endif
                self.loadShell(
                    theme: self.lastTheme ?? self.pendingTheme,
                    initialMarkdown: self.lastMarkdown ?? self.pendingMarkdown
                )
            }
        }

        func update(markdown: String, theme: MarkdownWebTheme) {
            let themeChanged = lastTheme != theme
            let contentChanged = lastMarkdown != markdown
            let shellNeedsReload = !isLoaded && !isShellLoading
            guard themeChanged || contentChanged || shellNeedsReload else { return }

            pendingMarkdown = markdown
            pendingTheme = theme

            if themeChanged {
                lastTheme = theme
                // The WKWebView's NSAppearance change (handled in the
                // representable's update path) flips `prefers-color-scheme`
                // automatically. We still nudge the page so highlight.js
                // swaps stylesheets even if the matchMedia listener is
                // slow to fire.
                if isLoaded {
                    applyTheme(theme)
                    if !contentChanged {
                        pushMarkdown(lastMarkdown ?? pendingMarkdown)
                    }
                }
            }

            if contentChanged {
                webContentProcessRecoveryAttempts = 0
                lastMarkdown = markdown
                if isLoaded {
                    pushMarkdown(markdown)
                } else if shellNeedsReload {
                    loadShell(theme: theme, initialMarkdown: markdown)
                }
            } else if shellNeedsReload {
                if webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts {
                    loadShell(theme: theme, initialMarkdown: markdown)
                }
            }
        }

        func renderedHTML(markdown: String? = nil) async -> String? {
            guard isLoaded else { return nil }
            if let markdown {
                guard await renderMarkdownForExport(markdown) else { return nil }
            }
            // We export an explicit "rendered HTML" getter from JS so callers
            // get the *content* div only, without the shell <style>/<script>.
            return await evaluateString("window.__cmuxRenderedHTML && window.__cmuxRenderedHTML()")
        }

        func renderedText() async -> String? {
            guard isLoaded else { return nil }
            return await evaluateString("window.__cmuxRenderedText && window.__cmuxRenderedText()")
        }

        private func evaluateString(_ script: String) async -> String? {
            guard let webView else { return nil }
            do {
                return try await webView.evaluateJavaScript(script) as? String
            } catch {
                return nil
            }
        }

        private func applyTheme(_ theme: MarkdownWebTheme) {
            guard let webView else { return }
            let payload = [
                "--bgColor-default": theme.background,
                "--bgColor-muted": theme.mutedBackground,
                "--bgColor-neutral-muted": theme.neutralMutedBackground,
                "--borderColor-default": theme.border,
                "--borderColor-muted": theme.mutedBorder,
                "--borderColor-neutral-muted": theme.mutedBorder
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = """
            (function(vars) {
              var content = document.getElementById('content');
              if (!content) { return; }
              Object.keys(vars).forEach(function(name) {
                content.style.setProperty(name, vars[name]);
              });
              content.style.background = 'transparent';
              if (window.__cmuxApplyTheme) { window.__cmuxApplyTheme(); }
            })(\(json));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: Bridge

        private func pushMarkdown(_ markdown: String) {
            guard let webView else { return }
#if DEBUG
            NSLog("MarkdownPanel.pushMarkdown bytes=\(markdown.utf8.count)")
#endif
            guard let js = Self.renderMarkdownScript(markdown) else { return }
            webView.evaluateJavaScript(js) { _, error in
#if DEBUG
                if let error {
                    NSLog("MarkdownPanel: pushMarkdown evaluateJavaScript failed: \(error)")
                }
#endif
            }
        }

        private func renderMarkdownForExport(_ markdown: String) async -> Bool {
            guard let webView, isLoaded else { return false }
            guard let js = Self.renderMarkdownScript(markdown) else { return false }
            do {
                _ = try await webView.evaluateJavaScript(js)
                lastMarkdown = markdown
                pendingMarkdown = markdown
                return true
            } catch {
#if DEBUG
                NSLog("MarkdownPanel: renderMarkdownForExport evaluateJavaScript failed: \(error)")
#endif
                return false
            }
        }

        private static func renderMarkdownScript(_ markdown: String) -> String? {
            // Send the raw markdown through a JSON literal so we don't have
            // to hand-escape backticks/backslashes/quotes for JS.
            guard let data = try? JSONSerialization.data(withJSONObject: [markdown]),
                  let arrayLiteral = String(data: data, encoding: .utf8) else { return nil }
            return """
            (function(md) {
              if (window.__cmuxRenderMarkdown) {
                window.__cmuxRenderMarkdown(md);
                return;
              }
              var el = document.getElementById('content') || document.body;
              function esc(s) {
                var div = document.createElement('div');
                div.textContent = String(s == null ? '' : s);
                return div.innerHTML;
              }
              el.innerHTML = '<pre style=\"color:#f85149;white-space:pre-wrap\">Markdown renderer failed to initialize. Showing raw source.\\n\\n' + esc(md) + '</pre>';
            })(\(arrayLiteral)[0]);
            """
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "cmuxLib",
                  let body = message.body as? [String: Any] else { return }
            if let lib = body["lib"] as? String {
                handleLibRequest(lib)
                return
            }
            if let action = body["action"] as? String {
#if DEBUG
                NSLog("MarkdownPanel.bridge action=\(action) body=\(body)")
#endif
                switch action {
                case "resolveMarkdownFile":
                    guard let requestId = body["requestId"] as? String,
                          let rawPath = body["path"] as? String else { return }
                    resolveMarkdownFile(rawPath, requestId: requestId)
                case "openMarkdownFile":
                    guard let rawPath = body["path"] as? String else { return }
                    if let resolved = resolvedMarkdownFilePath(rawPath) {
                        openMarkdownFile(resolved)
                    }
                default:
                    break
                }
            }
        }

        private var requestedLibs: Set<String> = []

        // MARK: WKURLSchemeHandler

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let requestURL = urlSchemeTask.request.url else {
                urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
                return
            }

            let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
            let load = ImageLoad()
            imageLoads[taskId] = load
            let reader = imageLoadTask(for: requestURL)
            load.reader = reader
            let sender = Task { [weak self, weak load] in
                defer {
                    if let load, self?.imageLoads[taskId] === load {
                        self?.imageLoads[taskId] = nil
                    }
                }
                let result = await reader.value
                guard !Task.isCancelled else { return }
                let response = URLResponse(
                    url: requestURL,
                    mimeType: result.mimeType,
                    expectedContentLength: result.data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                if !result.data.isEmpty {
                    urlSchemeTask.didReceive(result.data)
                }
                urlSchemeTask.didFinish()
            }
            load.sender = sender
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
            guard let load = imageLoads.removeValue(forKey: taskId) else { return }
            load.cancel()
        }

        func cancelImageLoads() {
            let loads = imageLoads.values
            imageLoads.removeAll()
            for load in loads {
                load.cancel()
            }
        }

        func cancelLocalImageLoads() {
            cancelImageLoads()
        }

        private func imageLoadTask(for requestURL: URL) -> Task<ImageLoadResult, Never> {
            let scheme = requestURL.scheme?.lowercased()
            if scheme == MarkdownWebRenderer.localImageURLScheme {
                let fileURL = localImageFileURL(from: requestURL)
                let mimeType = fileURL
                    .flatMap { Self.localImageMimeType(for: $0.pathExtension) } ?? "image/png"
                return Task.detached(priority: .userInitiated) {
                    guard let fileURL,
                          FileManager.default.isReadableFile(atPath: fileURL.path) else {
                        return ImageLoadResult(data: Data(), mimeType: mimeType)
                    }
                    let data = (try? Data(contentsOf: fileURL)) ?? Data()
                    return ImageLoadResult(data: data, mimeType: mimeType)
                }
            }

            if scheme == MarkdownWebRenderer.remoteImageURLScheme {
                let remoteURL = MarkdownRemoteImageSecurity.remoteImageURL(from: requestURL)
                return Task.detached(priority: .userInitiated) {
                    guard let remoteURL,
                          let fetched = await MarkdownRemoteImageFetcher.fetch(remoteURL) else {
                        return ImageLoadResult(data: Data(), mimeType: "image/png")
                    }
                    return ImageLoadResult(data: fetched.data, mimeType: fetched.mimeType)
                }
            }

            return Task.detached {
                ImageLoadResult(data: Data(), mimeType: "image/png")
            }
        }

        private func localImageFileURL(from requestURL: URL) -> URL? {
            guard requestURL.scheme?.lowercased() == MarkdownWebRenderer.localImageURLScheme,
                  let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
                  let rawFileURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let fileURL = URL(string: rawFileURL),
                  fileURL.isFileURL else {
                return nil
            }

            let markdownFilePath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdownFilePath.isEmpty else {
                return nil
            }

            let markdownDirectory = URL(fileURLWithPath: markdownFilePath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard markdownDirectory.path != "/" else {
                return nil
            }

            let markdownRoot = markdownDirectory.path.hasSuffix("/")
                ? markdownDirectory.path
                : markdownDirectory.path + "/"
            let standardizedURL = fileURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard standardizedURL.path.hasPrefix(markdownRoot),
                  Self.localImageMimeType(for: standardizedURL.pathExtension) != nil else {
                return nil
            }
            return standardizedURL
        }

        private static func localImageMimeType(for pathExtension: String) -> String? {
            switch pathExtension.lowercased() {
            case "png":
                return "image/png"
            case "jpg", "jpeg":
                return "image/jpeg"
            case "gif":
                return "image/gif"
            case "webp":
                return "image/webp"
            case "avif":
                return "image/avif"
            default:
                return nil
            }
        }

        private func resolveMarkdownFile(_ rawPath: String, requestId: String) {
            guard let webView else { return }
            let resolved = resolvedMarkdownFilePath(rawPath)
#if DEBUG
            NSLog("MarkdownPanel.resolve raw=\(rawPath) resolved=\(resolved ?? "nil")")
#endif
            let payload: [String: Any] = [
                "requestId": requestId,
                "exists": resolved != nil,
                "path": resolved ?? ""
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.__cmuxMarkdownFileResolved && window.__cmuxMarkdownFileResolved(\(json));", completionHandler: nil)
        }

        private func resolvedMarkdownFilePath(_ rawPath: String) -> String? {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard MarkdownPanelFileLinkResolver.isMarkdownPathLike(trimmed) else { return nil }
            return MarkdownPanelFileLinkResolver.resolve(rawPath: trimmed, relativeToMarkdownFile: filePath)
        }

        private func openMarkdownFile(_ path: String) {
#if DEBUG
            NSLog("MarkdownPanel.openMarkdownFile path=\(path)")
#endif
            guard let app = AppDelegate.shared,
                  let location = app.workspaceContainingPanel(
                      panelId: panelId,
                      preferredWorkspaceId: workspaceId
                  ),
                  let paneId = location.workspace.paneId(forPanelId: panelId) else { return }
            _ = location.workspace.newMarkdownSurface(
                inPane: paneId,
                filePath: path,
                focus: true
            )
        }

        private func handleLibRequest(_ lib: String) {
            guard let webView else { return }
            // Load each library at most once per WebView lifetime. State is
            // reset only when the shell is reloaded via loadShell(); theme
            // switches reuse the already-loaded libs.
            if requestedLibs.contains(lib) { return }
            requestedLibs.insert(lib)

            let assets = MarkdownViewerAssets.shared
            let sources: [String]
            switch lib {
            case "mermaid":
                sources = [assets.lazyAsset(name: "mermaid.min", ext: "js")]
            case "vega-lite":
                // Order matters: vega first, then vega-lite, then vega-embed.
                sources = [
                    assets.lazyAsset(name: "vega.min", ext: "js"),
                    assets.lazyAsset(name: "vega-lite.min", ext: "js"),
                    assets.lazyAsset(name: "vega-embed.min", ext: "js"),
                ]
            default:
                return
            }

            // Concatenate the bundled sources into a single evaluateJavaScript
            // call, then notify the page that the lib is ready. Any parse or
            // throw in the bundle surfaces through the completion handler.
            var injection = ""
            for src in sources where !src.isEmpty {
                injection += src
                injection += "\n;"
            }
            // JSON-encode the lib name to safely splice into JS.
            let libLiteral = (try? JSONSerialization.data(withJSONObject: [lib]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let suffix = "\nwindow.__cmuxLibLoaded && window.__cmuxLibLoaded(\(libLiteral)[0]);"
            webView.evaluateJavaScript(injection + suffix) { [weak self] _, error in
                if let error {
                    // Allow retry on next render if this attempt failed.
                    self?.requestedLibs.remove(lib)
#if DEBUG
                    NSLog("MarkdownPanel: failed to load \(lib): \(error)")
#endif
                }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if DEBUG
            NSLog("MarkdownPanel.webView.didFinish")
#endif
            isShellLoading = false
            isLoaded = true
            // pageZoom is a WKWebView-level property that survives loadHTMLString,
            // but re-apply defensively after a shell reload so a crash-recovery
            // path can never drop the configured zoom.
            applyFontSize(forceShellSync: true)
            // font-family is a DOM inline style on a freshly-created #content,
            // so it MUST be re-applied after every shell (re)load.
            applyFontFamily()
            applyMaxContentWidth()
            applyTheme(lastTheme ?? pendingTheme)
            // Replay last known markdown after the shell finishes loading.
            // Keep the recovery budget scoped to the current markdown payload:
            // a payload can crash after shell load during the render push.
            // Content changes reset the budget in `update(markdown:theme:)`.
            let md = lastMarkdown ?? pendingMarkdown
            lastMarkdown = md
            pushMarkdown(md)
            // The shell is loaded and the markdown payload has been pushed:
            // announce the render so CLI callers can await it (e.g. before
            // reparenting the surface) instead of sleeping.
            CmuxEventBus.shared.publishMarkdownRendered(
                workspaceId: workspaceId,
                surfaceId: panelId,
                filePath: filePath
            )
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleShellNavigationFailure(for: webView, error: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handleShellNavigationFailure(for: webView, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let currentWebView = self.webView, currentWebView === webView else { return }
#if DEBUG
            NSLog("MarkdownPanel.webView.webContentProcessDidTerminate")
#endif
            isShellLoading = false
            guard webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts else {
                isLoaded = false
                requestedLibs.removeAll()
                return
            }
            webContentProcessRecoveryAttempts += 1
            loadShell(
                theme: lastTheme ?? pendingTheme,
                initialMarkdown: lastMarkdown ?? pendingMarkdown
            )
        }

        /// Called when the host `MarkdownWebView` re-enters a window after
        /// having been detached (e.g. a pane drag re-parents the hosting
        /// views via `removeFromSuperview` → `addSubview`). While detached
        /// from the window WebKit can reclaim the WebContent process,
        /// leaving the panel permanently blank with no user-facing reload.
        /// Records, at the moment the host view leaves its window, whether the
        /// document was healthy. The blank state seen after re-entry is only
        /// treated as a detach artifact (and recovered with a fresh budget) if
        /// the shell was loaded when it was detached.
        /// Re-establish the WKWebView's remote layer hosting after a reparent.
        /// A hide/unhide cycle across a runloop turn forces WebKit to drop and
        /// re-create the layer host connection; synchronous toggles coalesce
        /// into a no-op.
        private func scheduleRemoteLayerNudge() {
            DispatchQueue.main.async { [weak self] in
                guard let webView = self?.webView, webView.window != nil else { return }
                webView.isHidden = true
                DispatchQueue.main.async { [weak self] in
                    guard let webView = self?.webView else { return }
                    webView.isHidden = false
#if DEBUG
                    NSLog("MarkdownPanel.remoteLayerNudge completed filePath=\(self?.filePath ?? "?")")
#endif
                }
            }
        }

        func handleViewLeftWindow() {
#if DEBUG
            NSLog("MarkdownPanel.handleViewLeftWindow isLoaded=\(isLoaded) isShellLoading=\(isShellLoading) filePath=\(filePath)")
#endif
            shellWasHealthyWhenDetached = isLoaded
            // A load still in flight at detach time is also recoverable: the
            // shell never got a chance to become healthy (e.g. the surface was
            // opened and immediately reparented into another pane). Exclude a
            // payload whose recovery budget is already exhausted so a crash
            // loop cannot launder a fresh budget through reparenting.
            shellWasLoadingWhenDetached = isShellLoading
                && webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts
            // A visible panel's webview leaving the window is either a
            // transient reparent (re-entry follows and recovery runs there) or
            // the start of an orphan (re-entry never comes). Arm the orphan
            // watchdog to distinguish: if the view is still windowless while
            // visible shortly after, request a SwiftUI rehost.
            if lastVisible == true {
                armOrphanWatchdog(delay: 1.0)
            }
        }

        func handleViewReenteredWindow() {
#if DEBUG
            NSLog("MarkdownPanel.handleViewReenteredWindow isLoaded=\(isLoaded) wasHealthy=\(shellWasHealthyWhenDetached) wasLoading=\(shellWasLoadingWhenDetached) filePath=\(filePath)")
#endif
            // A still-loaded shell survives the reparent with its DOM intact,
            // but WebKit's remote layer host is severed by the window hop and
            // the panel shows blank even though the WebContent process renders
            // fine (its snapshot has full content). Nudge the layer host back.
            guard !isLoaded else {
                scheduleRemoteLayerNudge()
                return
            }
            // Recover only when the document was healthy — or a load was
            // genuinely in flight — before the detach, so a payload that
            // exhausted its crash-recovery budget while attached (a crash
            // loop) is not granted a fresh budget by pane reparenting.
            guard shellWasHealthyWhenDetached || shellWasLoadingWhenDetached else { return }
            shellWasHealthyWhenDetached = false
            shellWasLoadingWhenDetached = false
            // A reload kicked off while detached can stall (no didFinish until
            // the view is back in a window), so reload unconditionally — even
            // mid-load. A deliberate reattach is not a crash loop, so restore
            // the recovery budget so the document repaints instead of staying
            // permanently blank.
            webContentProcessRecoveryAttempts = 0
            loadShell(
                theme: lastTheme ?? pendingTheme,
                initialMarkdown: lastMarkdown ?? pendingMarkdown
            )
        }

        private func handleShellNavigationFailure(for webView: WKWebView, error: Error) {
            guard let currentWebView = self.webView, currentWebView === webView, isShellLoading else { return }
#if DEBUG
            NSLog("MarkdownPanel.webView.navigationFailed error=\(error)")
#endif
            isShellLoading = false
            isLoaded = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The first load (loadHTMLString) has navigationType = .other —
            // allow it. Anything the user clicks (links, anchors, ...) we
            // route through the cmux tab/browser machinery.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
#if DEBUG
                NSLog("MarkdownPanel.nav linkActivated url=\(url.absoluteString)")
#endif
                if isInPageFragment(url) {
                    // Same-document fragment navigation (heading anchors)
                    // scrolls the panel — keep it native.
                    decisionHandler(.allow)
                    return
                }
                handleExternalLink(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // target=_blank / window.open from inside the rendered markdown.
            if let url = navigationAction.request.url {
                handleExternalLink(url)
            }
            return nil
        }

        // MARK: - Link routing

        /// Route a clicked link to a brand-new cmux browser tab in the same
        /// pane as this markdown panel — mirroring how Browser panels open
        /// child links via `openLinkInNewTab`. Falls back to the system
        /// browser only when the in-app browser is disabled or the panel
        /// can't be located in any workspace.
        private func handleExternalLink(_ url: URL) {
#if DEBUG
            NSLog("MarkdownPanel.handleExternalLink url=\(url.absoluteString)")
#endif
            // First preference: links that resolve to local markdown files
            // open as markdown tabs in cmux, not in the browser.
            let fileCandidate = url.scheme == "file" ? url.path : url.absoluteString
            if let markdownPath = resolvedMarkdownFilePath(fileCandidate) {
                openMarkdownFile(markdownPath)
                return
            }

            // Schemes the in-app browser doesn't (and shouldn't) handle:
            // mailto:, tel:, slack://, vscode://, file:// non-markdown, etc.
            // Route those to the system handler so the user's default app picks them up.
            if let scheme = url.scheme?.lowercased(),
               scheme != "http", scheme != "https" {
                NSWorkspace.shared.open(url)
                return
            }

            guard BrowserAvailabilitySettings.isEnabled() else {
                NSWorkspace.shared.open(url)
                return
            }

            guard let app = AppDelegate.shared,
                  let location = app.workspaceContainingPanel(
                      panelId: panelId,
                      preferredWorkspaceId: workspaceId
                  ),
                  let paneId = location.workspace.paneId(forPanelId: panelId) else {
                // No workspace context — last-resort fallback.
                NSWorkspace.shared.open(url)
                return
            }

            _ = location.workspace.newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: true
            )
        }

        private func isInPageFragment(_ url: URL) -> Bool {
            // Only same-document anchors should stay inside the WebView. With
            // a file base URL, WebKit resolves `#heading` to
            // `file:///current.md#heading`; links such as `other.md#heading`
            // must still route through the markdown-tab opener below.
            guard url.fragment != nil else { return false }
            if (url.scheme == nil || url.scheme == "about"), (url.host ?? "").isEmpty {
                return true
            }
            if url.isFileURL {
                let targetPath = (url.path as NSString).standardizingPath
                let currentPath = (filePath as NSString).standardizingPath
                let currentDirectory = ((filePath as NSString).deletingLastPathComponent as NSString).standardizingPath
                return targetPath == currentPath || targetPath == currentDirectory
            }
            return false
        }
    }
}
