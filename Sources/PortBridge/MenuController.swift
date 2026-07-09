import AppKit
import PortBridgeCore

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let appState: AppState
    private var addHostController: AddHostWindowController?
    private var isMenuOpen = false
    private var needsMenuRebuild = false

    init(appState: AppState) {
        self.appState = appState
        super.init()
        statusItem.button?.image = nil
        statusItem.button?.title = "PB"
        menu.delegate = self
        statusItem.menu = menu
        appState.onChange = { [weak self] in
            Task { @MainActor in
                self?.scheduleMenuRebuild()
            }
        }
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        needsMenuRebuild = false
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if needsMenuRebuild {
            needsMenuRebuild = false
            rebuildMenu()
        }
    }

    private func scheduleMenuRebuild() {
        if isMenuOpen {
            needsMenuRebuild = true
            return
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let proxyTitle = appState.proxyRunning
            ? "Proxy: http://*.localhost:\(appState.configuration.proxyPort)"
            : "Proxy stopped"
        menu.addItem(disabled(proxyTitle))
        if let error = appState.lastError {
            menu.addItem(disabled("Last error: \(error)"))
        }
        menu.addItem(.separator())

        if appState.hosts.isEmpty {
            menu.addItem(disabled("No SSH hosts yet"))
        } else {
            for host in appState.hosts {
                menu.addItem(hostMenuItem(host))
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Import ~/.ssh/config Hosts", action: #selector(importSSHConfig)))
        menu.addItem(actionItem("Add Host...", action: #selector(addHost)))
        menu.addItem(actionItem("Open Config File", action: #selector(openConfig)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Restart Proxy", action: #selector(restartProxy)))
        menu.addItem(actionItem("Quit PortBridge", action: #selector(quit)))
    }

    private func hostMenuItem(_ host: HostProfile) -> NSMenuItem {
        let hostServices = services(for: host)
        let webCount = hostServices.filter { $0.status == .web }.count
        let count = webCount > 0 ? "\(webCount)" : "\(hostServices.count)"
        let connection = host.enabled ? "Connected" : "Disabled"
        let scanState = appState.isScanning(host.id) ? "Scanning" : connection
        let item = NSMenuItem(title: "\(host.displayName)  \(scanState)  \(count)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let toggle = actionItem(host.enabled ? "Disable Host" : "Enable Host", action: #selector(toggleHost(_:)))
        toggle.representedObject = host.id.uuidString
        submenu.addItem(toggle)

        let autoForward = actionItem("Auto Forward New Ports", action: #selector(toggleHostAutoForward(_:)))
        autoForward.representedObject = host.id.uuidString
        autoForward.state = host.autoForward ? .on : .off
        submenu.addItem(autoForward)

        let scan = actionItem("Scan Now", action: #selector(scanHost(_:)))
        scan.representedObject = host.id.uuidString
        submenu.addItem(scan)

        if hostServices.contains(where: { $0.enabled }) {
            let disableAll = actionItem("Disable All Forwards", action: #selector(disableAllForwards(_:)))
            disableAll.representedObject = host.id.uuidString
            submenu.addItem(disableAll)
        }

        if let summary = appState.lastScanSummary(for: host.id) {
            submenu.addItem(disabled(summary))
        }

        let remove = actionItem("Remove Host", action: #selector(removeHost(_:)))
        remove.representedObject = host.id.uuidString
        submenu.addItem(remove)
        submenu.addItem(.separator())

        let activeServices = hostServices.filter { $0.enabled && $0.status == .web }
        let disabledServices = hostServices.filter { !$0.enabled || $0.status != .web }

        if hostServices.isEmpty {
            submenu.addItem(disabled("No ports discovered yet"))
        } else if activeServices.isEmpty {
            submenu.addItem(disabled("No HTTP services detected"))
        } else {
            for service in activeServices {
                submenu.addItem(serviceMenuItem(service))
            }
        }

        if !disabledServices.isEmpty {
            let disabledItem = NSMenuItem(title: "Disabled Ports  \(disabledServices.count)", action: nil, keyEquivalent: "")
            let disabledMenu = NSMenu()
            for service in disabledServices {
                disabledMenu.addItem(serviceMenuItem(service))
            }
            disabledItem.submenu = disabledMenu
            submenu.addItem(disabledItem)
        }

        item.submenu = submenu
        return item
    }

    private func services(for host: HostProfile) -> [ServiceRecord] {
        appState.visibleServices.filter { $0.hostID == host.id }
    }

    private func serviceMenuItem(_ service: ServiceRecord) -> NSMenuItem {
        let status = service.status == .web ? service.scheme?.rawValue.uppercased() ?? "WEB" : service.status.rawValue
        let title = service.title ?? "\(service.remotePort.port)"
        let item = NSMenuItem(title: "\(title)  :\(service.remotePort.port)  \(status)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let open = actionItem("Open Pretty URL", action: #selector(openService(_:)))
        open.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Open")
        open.representedObject = service.id.uuidString
        open.isEnabled = service.enabled && service.status == .web
        submenu.addItem(open)

        let copy = actionItem("Copy Pretty URL", action: #selector(copyServiceURL(_:)))
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copy.representedObject = service.id.uuidString
        copy.isEnabled = service.enabled && service.status == .web
        submenu.addItem(copy)

        let localOpen = actionItem("Open Localhost URL", action: #selector(openLocalhostService(_:)))
        localOpen.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Open Localhost")
        localOpen.representedObject = service.id.uuidString
        localOpen.isEnabled = service.enabled
        submenu.addItem(localOpen)

        let localCopy = actionItem("Copy Localhost URL", action: #selector(copyLocalhostServiceURL(_:)))
        localCopy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Localhost")
        localCopy.representedObject = service.id.uuidString
        localCopy.isEnabled = service.enabled
        submenu.addItem(localCopy)

        let toggle = actionItem(service.enabled ? "Disable Forward" : "Enable Forward", action: #selector(toggleService(_:)))
        toggle.representedObject = service.id.uuidString
        submenu.addItem(toggle)

        if service.status != .web || service.scheme == nil {
            let forceHTTP = actionItem("Force HTTP Route", action: #selector(forceHTTP(_:)))
            forceHTTP.representedObject = service.id.uuidString
            submenu.addItem(forceHTTP)

            let forceHTTPS = actionItem("Force HTTPS Route", action: #selector(forceHTTPS(_:)))
            forceHTTPS.representedObject = service.id.uuidString
            submenu.addItem(forceHTTPS)
        }

        submenu.addItem(.separator())
        submenu.addItem(disabled("Pretty: \(service.routeHost)"))
        submenu.addItem(disabled("Remote: \(service.remotePort.bindAddress):\(service.remotePort.port)"))
        submenu.addItem(disabled("Localhost: 127.0.0.1:\(service.localPort)"))
        if let error = service.lastError {
            submenu.addItem(disabled(error))
        }

        item.submenu = submenu
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func importSSHConfig() {
        appState.importSSHConfigHosts()
    }

    @objc private func restartProxy() {
        appState.startProxy()
    }

    @objc private func addHost() {
        let controller = AddHostWindowController { [weak self] alias, hostname, user, port in
            guard let self else { return }
            appState.addManualHost(
                alias: alias,
                hostname: hostname,
                user: user,
                port: port
            )
            addHostController = nil
        }
        addHostController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func field(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        return field
    }

    @objc private func toggleHost(_ sender: NSMenuItem) {
        guard let id = uuid(sender) else { return }
        let enabled = !(appState.hosts.first(where: { $0.id == id })?.enabled ?? false)
        appState.setHost(id, enabled: enabled)
    }

    @objc private func scanHost(_ sender: NSMenuItem) {
        guard let id = uuid(sender) else { return }
        appState.scanNow(id)
    }

    @objc private func toggleHostAutoForward(_ sender: NSMenuItem) {
        guard let id = uuid(sender),
              let host = appState.hosts.first(where: { $0.id == id }) else { return }
        appState.setHostAutoForward(id, enabled: !host.autoForward)
    }

    @objc private func disableAllForwards(_ sender: NSMenuItem) {
        guard let id = uuid(sender) else { return }
        appState.disableAllForwards(for: id)
    }

    @objc private func removeHost(_ sender: NSMenuItem) {
        guard let id = uuid(sender) else { return }
        appState.removeHost(id)
    }

    @objc private func toggleService(_ sender: NSMenuItem) {
        guard let id = uuid(sender),
              let service = appState.services.first(where: { $0.id == id }) else { return }
        appState.setService(id, enabled: !service.enabled)
    }

    @objc private func forceHTTP(_ sender: NSMenuItem) {
        guard let id = uuid(sender) else { return }
        appState.forceHTTP(id)
    }

    @objc private func forceHTTPS(_ sender: NSMenuItem) {
        guard let id = uuid(sender) else { return }
        appState.forceHTTP(id, scheme: .https)
    }

    @objc private func openService(_ sender: NSMenuItem) {
        guard let id = uuid(sender),
              let service = appState.services.first(where: { $0.id == id }),
              let url = appState.url(for: service) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyServiceURL(_ sender: NSMenuItem) {
        guard let id = uuid(sender),
              let service = appState.services.first(where: { $0.id == id }),
              let url = appState.url(for: service) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func openLocalhostService(_ sender: NSMenuItem) {
        guard let id = uuid(sender),
              let service = appState.services.first(where: { $0.id == id }),
              let url = appState.localhostURL(for: service) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLocalhostServiceURL(_ sender: NSMenuItem) {
        guard let id = uuid(sender),
              let service = appState.services.first(where: { $0.id == id }),
              let url = appState.localhostURL(for: service) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func openConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([appState.settingsStore.configurationURL])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func uuid(_ item: NSMenuItem) -> UUID? {
        guard let text = item.representedObject as? String else { return nil }
        return UUID(uuidString: text)
    }
}

@MainActor
private final class AddHostWindowController: NSWindowController {
    private let aliasField = NSTextField()
    private let hostnameField = NSTextField()
    private let userField = NSTextField()
    private let portField = NSTextField()
    private let onAdd: (String, String, String, Int) -> Void

    init(onAdd: @escaping (String, String, String, Int) -> Void) {
        self.onAdd = onAdd
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add SSH Host"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
        ])

        let heading = NSTextField(labelWithString: "Add SSH Host")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(heading)

        let helper = NSTextField(wrappingLabelWithString: "Use an SSH config alias, or provide hostname, user, and port manually. Manual entries can still have a friendly display alias.")
        helper.font = .systemFont(ofSize: 13)
        helper.textColor = .secondaryLabelColor
        helper.translatesAutoresizingMaskIntoConstraints = false
        helper.widthAnchor.constraint(equalToConstant: 464).isActive = true
        root.addArrangedSubview(helper)

        let form = NSGridView(views: [
            [label("Alias"), configuredField(aliasField, placeholder: "devbox")],
            [label("Hostname"), configuredField(hostnameField, placeholder: "optional if alias is in SSH config")],
            [label("User"), configuredField(userField, placeholder: "optional")],
            [label("Port"), configuredField(portField, placeholder: "22")],
        ])
        form.rowSpacing = 10
        form.columnSpacing = 14
        form.translatesAutoresizingMaskIntoConstraints = false
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 350
        root.addArrangedSubview(form)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        buttonRow.addArrangedSubview(cancel)

        let add = NSButton(title: "Add", target: self, action: #selector(add))
        add.bezelStyle = .rounded
        add.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(add)

        root.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configuredField(_ field: NSTextField, placeholder: String) -> NSTextField {
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.font = .systemFont(ofSize: 14)
        return field
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func add() {
        onAdd(
            aliasField.stringValue,
            hostnameField.stringValue,
            userField.stringValue,
            Int(portField.stringValue) ?? 22
        )
        window?.close()
    }
}
