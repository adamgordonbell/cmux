import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Pure AppKit header bar with folder icon, path label, and hidden files toggle.
///
/// The path doubles as the breadcrumb: clicking it offers every ancestor of the
/// current root, plus a way back to auto-follow. `set-root` otherwise has no
/// inverse in the UI — once the sidebar is pinned narrow (by the context menu,
/// the CLI, or the auto-pin hook) widening it again meant going to a terminal.
final class FileExplorerHeaderView: NSView {
    private let iconView = CmuxResolvedIconImageView()
    private let retryButton = NSButton()
    private var retry: (() -> Void)?
    private var refresh: (() -> Void)?
    private let pathLabel = NSTextField(labelWithString: "")
    private let chevronView = CmuxResolvedIconImageView()
    private var heightConstraint: NSLayoutConstraint?
    private var displayPath = ""
    private var rootPath = ""
    private var quickSearchQuery: String?

    /// Invoked with the chosen ancestor, or `nil` for "follow the shell again".
    var onSelectRoot: ((String?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        applyFonts()
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chevronView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(pathLabel)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        retryButton.bezelStyle = .inline
        retryButton.isBordered = false
        retryButton.target = self
        retryButton.action = #selector(retryFiles)
        retryButton.toolTip = String(localized: "common.retry", defaultValue: "Retry")
        retryButton.setAccessibilityLabel(retryButton.toolTip)
        addSubview(retryButton)
        addSubview(chevronView)

        let heightConstraint = heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: RightSidebarChromeMetrics.contentIconLeadingPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.contentIconFrameSize),
            iconView.heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.contentIconFrameSize),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: RightSidebarChromeMetrics.contentIconTextSpacing),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -2),

            chevronView.trailingAnchor.constraint(equalTo: retryButton.leadingAnchor, constant: -4),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 8),
            chevronView.heightAnchor.constraint(equalToConstant: 8),

            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 18),
        ])
        applyHeaderState()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard quickSearchQuery == nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        // While quick-search owns the header the path shown isn't a directory,
        // so there is nothing coherent to navigate to.
        guard quickSearchQuery == nil, !rootPath.isEmpty else {
            super.mouseDown(with: event)
            return
        }

        let menu = NSMenu()
        let current = NSMenuItem(
            title: (rootPath as NSString).lastPathComponent,
            action: nil,
            keyEquivalent: ""
        )
        current.state = .on
        menu.addItem(current)

        let ancestors = FileExplorerRootPinning.ancestors(of: rootPath)
        if !ancestors.isEmpty {
            menu.addItem(.separator())
            for ancestor in ancestors {
                let item = NSMenuItem(
                    title: abbreviate(ancestor),
                    action: #selector(selectAncestor(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = ancestor
                menu.addItem(item)
            }
        }

        // Recents come after the ancestors because ancestors are the "widen from
        // here" move — same subtree, one click. Recents are the lateral jump.
        let recents = FileExplorerRecentRoots.list(excluding: rootPath)
        if !recents.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(
                title: String(localized: "fileExplorer.header.recent", defaultValue: "Recent"),
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)
            for recent in recents {
                let item = NSMenuItem(
                    title: abbreviate(recent),
                    action: #selector(selectAncestor(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = recent
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let autoItem = NSMenuItem(
            title: String(
                localized: "fileExplorer.header.followShell",
                defaultValue: "Follow Shell Directory"
            ),
            action: #selector(selectAutoFollow(_:)),
            keyEquivalent: ""
        )
        autoItem.target = self
        menu.addItem(autoItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: 0), in: self)
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    @objc private func selectAncestor(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onSelectRoot?(path)
    }

    @objc private func selectAutoFollow(_ sender: NSMenuItem) {
        onSelectRoot?(nil)
    }

    func applyFonts() {
        pathLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        heightConstraint?.constant = RightSidebarChromeMetrics.secondaryBarHeight
    }

    @objc private func retryFiles() { (retry ?? refresh)?() }

    /// `retry` (Cloud) wins over `refresh` for the one trailing button; with
    /// neither the button hides.
    func update(
        displayPath: String,
        rootPath: String,
        retry: (() -> Void)? = nil,
        refresh: (() -> Void)? = nil
    ) {
        self.retry = retry
        self.refresh = refresh
        retryButton.isHidden = retry == nil && (refresh == nil || rootPath.isEmpty)
        let toolTip = retry != nil
            ? String(localized: "common.retry", defaultValue: "Retry")
            : String(localized: "fileExplorer.header.refresh", defaultValue: "Refresh")
        if retryButton.toolTip != toolTip {
            retryButton.toolTip = toolTip
            retryButton.setAccessibilityLabel(toolTip)
        }
        guard self.displayPath != displayPath || self.rootPath != rootPath else { return }
        self.displayPath = displayPath
        self.rootPath = rootPath
        applyHeaderState()
    }

    func updateQuickSearch(query: String?) {
        guard quickSearchQuery != query else { return }
        quickSearchQuery = query
        applyHeaderState()
    }

    private func applyHeaderState() {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        if let quickSearchQuery {
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "magnifyingglass", accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: .secondaryLabelColor,
                symbolWeight: .regular
            ))
            pathLabel.stringValue = "/" + quickSearchQuery
            pathLabel.toolTip = pathLabel.stringValue
            chevronView.isHidden = true
        } else {
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "folder.fill", accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: .secondaryLabelColor,
                symbolWeight: .regular
            ))
            pathLabel.stringValue = displayPath
            pathLabel.toolTip = String(
                localized: "fileExplorer.header.tooltip",
                defaultValue: "\(displayPath) — click to change the sidebar root"
            )
            chevronView.isHidden = rootPath.isEmpty
            chevronView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "chevron.down", accessibilityDescription: nil),
                size: NSSize(width: 8, height: 8),
                tintColor: .tertiaryLabelColor,
                symbolWeight: .semibold
            ))
        }
        window?.invalidateCursorRects(for: self)
    }
}
