import AppKit
import PortBridgeCore
import SwiftUI

@MainActor
final class MenuController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let appState: AppState
    private let refreshModel = PopoverRefreshModel()
    private var addHostController: AddHostWindowController?
    private var hostingController: NSHostingController<PortBridgePopoverView>?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        configureStatusItem()
        configurePopover()
        appState.onChange = { [weak self] in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.refreshModel.refresh()
            }
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = "PB"
        button.target = self
        button.action = #selector(togglePopover)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let controller = NSHostingController(rootView: makePopoverView())
        popover.contentSize = preferredPopoverSize()
        controller.view.frame = NSRect(origin: .zero, size: popover.contentSize)
        hostingController = controller
        popover.contentViewController = controller
    }

    private func makePopoverView() -> PortBridgePopoverView {
        PortBridgePopoverView(
            appState: appState,
            refreshModel: refreshModel,
            size: popover.contentSize,
            actions: makeActions()
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            resizePopoverForCurrentContent()
            refreshModel.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func resizePopoverForCurrentContent() {
        let size = preferredPopoverSize()
        popover.contentSize = size
        hostingController?.rootView = PortBridgePopoverView(
            appState: appState,
            refreshModel: refreshModel,
            size: size,
            actions: makeActions()
        )
    }

    private func preferredPopoverSize() -> NSSize {
        let width: CGFloat = 640
        let maxHeight = min(NSScreen.main?.visibleFrame.height ?? 820, 820) - 80
        let height = min(max(260, estimatedContentHeight()), maxHeight)
        return NSSize(width: width, height: height)
    }

    private func estimatedContentHeight() -> CGFloat {
        var height: CGFloat = 105
        if appState.lastError != nil {
            height += 42
        }

        if appState.hosts.isEmpty {
            return height + 96
        }

        for host in appState.hosts {
            let hostServices = appState.visibleServices.filter { $0.hostID == host.id }
            let activeServices = hostServices.filter { $0.enabled && $0.status == .web }
            let disabledServices = hostServices.filter { !$0.enabled || $0.status != .web }
            var panelHeight: CGFloat = 64

            if activeServices.isEmpty && disabledServices.isEmpty {
                panelHeight += 34
            }
            if !activeServices.isEmpty {
                panelHeight += 28
                panelHeight += CGFloat(activeServices.count) * 58
                if activeServices.contains(where: \.enabled) {
                    panelHeight += 28
                }
            }
            if !disabledServices.isEmpty {
                panelHeight += 32
            }

            height += panelHeight + 14
        }
        return height
    }

    private func makeActions() -> PortBridgePopoverActions {
        PortBridgePopoverActions(
            importSSHConfig: { [weak self] in self?.importSSHConfig() },
            addHost: { [weak self] in self?.addHost() },
            openConfig: { [weak self] in self?.openConfig() },
            openIndex: { [weak self] in self?.openIndex() },
            restartProxy: { [weak self] in self?.restartProxy() },
            quit: { [weak self] in self?.quit() },
            toggleHost: { [weak self] id in self?.toggleHost(id) },
            toggleHostAutoForward: { [weak self] id in self?.toggleHostAutoForward(id) },
            scanHost: { [weak self] id in self?.scanHost(id) },
            disableAllForwards: { [weak self] id in self?.disableAllForwards(id) },
            removeHost: { [weak self] id in self?.removeHost(id) },
            toggleService: { [weak self] id in self?.toggleService(id) },
            forceHTTP: { [weak self] id in self?.forceHTTP(id) },
            forceHTTPS: { [weak self] id in self?.forceHTTPS(id) },
            openPrettyURL: { [weak self] id in self?.openService(id) },
            copyPrettyURL: { [weak self] id in self?.copyServiceURL(id) },
            openLocalhostURL: { [weak self] id in self?.openLocalhostService(id) },
            copyLocalhostURL: { [weak self] id in self?.copyLocalhostServiceURL(id) }
        )
    }

    private func services(for host: HostProfile) -> [ServiceRecord] {
        appState.visibleServices.filter { $0.hostID == host.id }
    }

    private func importSSHConfig() {
        appState.importSSHConfigHosts()
    }

    private func restartProxy() {
        appState.startProxy()
        refreshModel.refresh()
    }

    private func addHost() {
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

    private func toggleHost(_ id: UUID) {
        let enabled = !(appState.hosts.first(where: { $0.id == id })?.enabled ?? false)
        appState.setHost(id, enabled: enabled)
    }

    private func scanHost(_ id: UUID) {
        appState.scanNow(id)
    }

    private func toggleHostAutoForward(_ id: UUID) {
        guard let host = appState.hosts.first(where: { $0.id == id }) else { return }
        appState.setHostAutoForward(id, enabled: !host.autoForward)
    }

    private func disableAllForwards(_ id: UUID) {
        appState.disableAllForwards(for: id)
    }

    private func removeHost(_ id: UUID) {
        appState.removeHost(id)
    }

    private func toggleService(_ id: UUID) {
        guard let service = appState.services.first(where: { $0.id == id }) else { return }
        appState.setService(id, enabled: !service.enabled)
    }

    private func forceHTTP(_ id: UUID) {
        appState.forceHTTP(id)
    }

    private func forceHTTPS(_ id: UUID) {
        appState.forceHTTP(id, scheme: .https)
    }

    private func openService(_ id: UUID) {
        guard let service = appState.services.first(where: { $0.id == id }),
              let url = appState.url(for: service) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyServiceURL(_ id: UUID) {
        guard let service = appState.services.first(where: { $0.id == id }),
              let url = appState.url(for: service) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func openLocalhostService(_ id: UUID) {
        guard let service = appState.services.first(where: { $0.id == id }),
              let url = appState.localhostURL(for: service) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyLocalhostServiceURL(_ id: UUID) {
        guard let service = appState.services.first(where: { $0.id == id }),
              let url = appState.localhostURL(for: service) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func openConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([appState.settingsStore.configurationURL])
    }

    private func openIndex() {
        guard let url = URL(string: "http://127.0.0.1:\(appState.configuration.proxyPort)/") else { return }
        NSWorkspace.shared.open(url)
    }

    private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
private final class PopoverRefreshModel: ObservableObject {
    @Published var revision = 0

    func refresh() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            revision &+= 1
        }
    }
}

@MainActor
private struct PortBridgePopoverActions {
    var importSSHConfig: () -> Void
    var addHost: () -> Void
    var openConfig: () -> Void
    var openIndex: () -> Void
    var restartProxy: () -> Void
    var quit: () -> Void
    var toggleHost: (UUID) -> Void
    var toggleHostAutoForward: (UUID) -> Void
    var scanHost: (UUID) -> Void
    var disableAllForwards: (UUID) -> Void
    var removeHost: (UUID) -> Void
    var toggleService: (UUID) -> Void
    var forceHTTP: (UUID) -> Void
    var forceHTTPS: (UUID) -> Void
    var openPrettyURL: (UUID) -> Void
    var copyPrettyURL: (UUID) -> Void
    var openLocalhostURL: (UUID) -> Void
    var copyLocalhostURL: (UUID) -> Void
}

@MainActor
private struct PortBridgePopoverView: View {
    let appState: AppState
    @ObservedObject var refreshModel: PopoverRefreshModel
    let size: NSSize
    let actions: PortBridgePopoverActions

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = appState.lastError {
                Text("Last error: \(error)")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if appState.hosts.isEmpty {
                        emptyState
                    } else {
                        ForEach(appState.hosts) { host in
                            HostPanel(
                                host: host,
                                services: services(for: host),
                                scanSummary: appState.lastScanSummary(for: host.id),
                                actions: actions
                            )
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("PortBridge")
                .font(.system(size: 17, weight: .semibold))
            Text(verbatim: appState.proxyRunning ? "http://*.localhost:\(appState.configuration.proxyPort)" : "Proxy stopped")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(appState.proxyRunning ? Color.secondary : Color.red)
                .lineLimit(1)
            Spacer()
            Button("Index", action: actions.openIndex)
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .disabled(!appState.proxyRunning)
                .help("Open PortBridge index")
            iconButton("Restart proxy", systemName: "arrow.clockwise", action: actions.restartProxy)
            iconButton("Open config", systemName: "doc.text.magnifyingglass", action: actions.openConfig)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Import SSH Config", action: actions.importSSHConfig)
            Button("Add Host", action: actions.addHost)
            Spacer()
            Button("Quit", action: actions.quit)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No SSH hosts yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Import ~/.ssh/config or add a host manually to start scanning.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func services(for host: HostProfile) -> [ServiceRecord] {
        appState.visibleServices.filter { $0.hostID == host.id }
    }
}

@MainActor
private struct HostPanel: View {
    let host: HostProfile
    let services: [ServiceRecord]
    let scanSummary: String?
    let actions: PortBridgePopoverActions
    @State private var disabledPortsExpanded = false

    private var activeServices: [ServiceRecord] {
        services.filter { $0.enabled && $0.status == .web }
    }

    private var disabledServices: [ServiceRecord] {
        services.filter { !$0.enabled || $0.status != .web }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(host.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                            .help(statusText)
                    }
                    if let scanSummary {
                        Text(scanSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Toggle("Auto", isOn: Binding(
                    get: { host.autoForward },
                    set: { _ in actions.toggleHostAutoForward(host.id) }
                ))
                .toggleStyle(.checkbox)
                .help("Auto forward new HTTP/HTTPS ports")
                Button(host.enabled ? "Disable" : "Enable") {
                    actions.toggleHost(host.id)
                }
                Button("Scan") {
                    actions.scanHost(host.id)
                }
                iconButton("Remove host", systemName: "trash", role: .destructive) {
                    actions.removeHost(host.id)
                }
            }

            if activeServices.isEmpty && disabledServices.isEmpty {
                Text("No ports discovered yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }

            if !activeServices.isEmpty {
                serviceHeader("Active HTTP/HTTPS", count: activeServices.count)
                ForEach(activeServices) { service in
                    ServiceRow(service: service, actions: actions)
                }
                if activeServices.contains(where: \.enabled) {
                    Button("Disable All Forwards") {
                        actions.disableAllForwards(host.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                }
            }

            if !disabledServices.isEmpty {
                DisclosureGroup(isExpanded: $disabledPortsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(disabledServices) { service in
                            ServiceRow(service: service, actions: actions)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Text("Disabled Ports")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(disabledServices.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: String {
        return host.enabled ? "Connected" : "Disabled"
    }

    private var statusColor: Color {
        return host.enabled ? .green : .secondary
    }

    private func serviceHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }
}

@MainActor
private struct ServiceRow: View {
    let service: ServiceRecord
    let actions: PortBridgePopoverActions

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(service.title ?? "\(service.remotePort.port)")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(verbatim: ":\(service.remotePort.port)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(detailText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if service.enabled {
                if service.status == .web {
                    iconButton("Open pretty URL", systemName: "globe") {
                        actions.openPrettyURL(service.id)
                    }
                    iconButton("Copy pretty URL", systemName: "doc.on.doc") {
                        actions.copyPrettyURL(service.id)
                    }
                }
                iconButton("Open localhost URL", systemName: "link") {
                    actions.openLocalhostURL(service.id)
                }
                iconButton("Copy localhost URL", systemName: "square.on.square") {
                    actions.copyLocalhostURL(service.id)
                }
                if service.status != .web || service.scheme == nil {
                    Button("HTTP") {
                        actions.forceHTTP(service.id)
                    }
                    .controlSize(.small)
                    Button("HTTPS") {
                        actions.forceHTTPS(service.id)
                    }
                    .controlSize(.small)
                }
                iconButton("Disable forward", systemName: "pause.circle") {
                    actions.toggleService(service.id)
                }
            } else {
                Button("Enable") {
                    actions.toggleService(service.id)
                }
                .controlSize(.small)
                Button("HTTP") {
                    actions.forceHTTP(service.id)
                }
                .controlSize(.small)
                Button("HTTPS") {
                    actions.forceHTTPS(service.id)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statusText: String {
        if service.status == .web {
            return service.scheme?.rawValue.uppercased() ?? "WEB"
        }
        return service.status.rawValue
    }

    private var detailText: String {
        let local = "127.0.0.1:\(service.localPort)"
        let remote = "\(service.remotePort.bindAddress):\(service.remotePort.port)"
        if service.enabled, service.status == .web {
            return "\(service.routeHost)  ->  \(local)  ->  \(remote)"
        }
        return "\(local)  ->  \(remote)"
    }
}

@MainActor
private func iconButton(
    _ help: String,
    systemName: String,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
) -> some View {
    Button(role: role, action: action) {
        Image(systemName: systemName)
            .frame(width: 18, height: 18)
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .help(help)
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
