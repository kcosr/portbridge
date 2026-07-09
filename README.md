# PortBridge

PortBridge is a native macOS menu-bar app for discovering HTTP and HTTPS services on SSH hosts and exposing them through local browser URLs.

It is built for dev containers, VMs, remote workstations, and local SSH targets where services bind to the remote host's `localhost` and are otherwise awkward to open from macOS.

PortBridge does not start your services. It connects to a host with the system `ssh` binary, scans for listening TCP ports, creates local SSH forwards when you enable a service, probes those forwards for HTTP or HTTPS, and gives you click-to-open URLs.

## Current State

- Native macOS menu-bar app, shown as `PB`.
- Swift Package Manager project.
- Uses AppKit, SwiftUI, Network.framework, and `/usr/bin/ssh`.
- Stores state in `~/Library/Application Support/PortBridge/config.json`.
- Local reverse proxy defaults to port `8088`.
- Local SSH tunnel ports are allocated automatically from `24000...39999`, preferring the original remote port when it is free.

## Features

- Import hosts from `~/.ssh/config`.
- Add hosts manually with alias, hostname, user, and SSH port.
- Enable or disable each host.
- Scan enabled hosts on an interval and on demand.
- Auto-forward new ports per host, default off.
- Track discovered ports even when auto-forward is off.
- Keep disabled or unknown ports in a collapsed `Disabled Ports` section.
- Filter known never-forward ports, currently SSH port `22`.
- Hide ports that prove they are not HTTP or HTTPS.
- Open or copy pretty proxy URLs.
- Open or copy raw `localhost` tunnel URLs.
- Force HTTP or HTTPS routing when probing cannot infer the service correctly.
- Support upstream HTTP and HTTPS services, including self-signed dev certificates.
- Provide a proxy index page listing active forwards.
- Avoid `/etc/hosts` for `.localhost` routes.

## How It Works

```text
macOS browser
  |
  | http://p3000.devbox.localhost:8088/
  v
PortBridge reverse proxy
  |
  | 127.0.0.1:<allocated local tunnel port>
  v
ssh -L 127.0.0.1:<local>:<remote bind>:<remote port> devbox
  |
  v
remote service bound to 127.0.0.1:<remote port>
```

PortBridge runs scans with SSH and one of the common remote socket tools:

- `ss -H -ltn`
- `netstat`
- `lsof`

When a port is enabled, PortBridge starts an SSH tunnel like:

```bash
ssh -N -T -L 127.0.0.1:<localPort>:<remoteBind>:<remotePort> <host>
```

It then probes the local tunnel with HTTP first and HTTPS second. If an HTTP response clearly says the plain HTTP request was sent to an HTTPS port, PortBridge retries and records the service as HTTPS.

## URLs

PortBridge gives each active HTTP/HTTPS service two useful URL styles.

Pretty proxy URL:

```text
http://p18080.aw-ubuntu.localhost:8088/
```

Raw local tunnel URL:

```text
http://127.0.0.1:65378/
https://127.0.0.1:53602/
```

The pretty URL always talks HTTP to the local PortBridge proxy. The proxy can then talk either HTTP or HTTPS to the local tunnel, depending on what the probe detected or what you forced.

The raw local tunnel URL uses the detected service scheme directly. If a service is detected as HTTPS, the raw URL is `https://127.0.0.1:<localPort>/`.

## Proxy Index

Open the index from the popover header, or visit:

```text
http://127.0.0.1:8088/
```

The index lists active forwards as clickable links. It is served when the proxy receives a request for `localhost`, `127.0.0.1`, or `::1` without a service subdomain.

If you visit an unknown `.localhost` route, PortBridge returns a small 404 page that also lists the active routes.

## Menu-Bar UI

Click `PB` in the macOS menu bar to open the popover.

Top bar:

- `Index`: opens the proxy index page.
- Restart icon: restarts the local reverse proxy.
- Config icon: opens the config file in Finder.

Each host panel shows:

- Host display name.
- Green dot when enabled, gray dot when disabled.
- Last scan summary.
- `Auto`: toggles automatic forwarding of newly discovered ports.
- `Enable` / `Disable`: toggles the host.
- `Scan`: scans immediately.
- Trash icon: removes the host and its services.

Active service rows show:

- Service title when available, otherwise the port number.
- Remote port and detected scheme.
- Pretty route, local tunnel port, and remote bind/port.
- Globe icon: open pretty proxy URL.
- Copy icon: copy pretty proxy URL.
- Link icon: open raw localhost tunnel URL.
- Copy icon: copy raw localhost tunnel URL.
- Pause icon: disable the forward.

Disabled or unprobed ports live under a collapsed `Disabled Ports` disclosure group. Open it to enable a port or force an HTTP/HTTPS route.

## Auto Forwarding

Auto-forward is per-host and defaults to off.

When auto-forward is off:

- PortBridge still scans and remembers listening ports.
- New ports are not tunneled or probed automatically.
- Discovered ports appear under `Disabled Ports`.
- You can enable a specific port manually.

When auto-forward is on:

- Newly discovered ports are assigned a local tunnel port.
- PortBridge starts an SSH forward.
- The tunnel is probed for HTTP/HTTPS.
- HTTP/HTTPS services appear under `Active HTTP/HTTPS`.
- Non-HTTP services are hidden after probing.

Turning auto-forward off disables all current forwards for that host.

## Port Filtering

PortBridge has a central never-forward list in `RemotePortScanner.neverForwardPorts`.

Current list:

```swift
[22]
```

Those ports are filtered during scanning, hidden from visible services, and removed from legacy saved state during config normalization.

Ports that are reachable but do not respond as HTTP or HTTPS are marked internally as `notHTTP` and hidden from the popover. The app is intentionally focused on browser services.

## HTTPS

PortBridge handles two separate HTTPS cases:

1. Remote service is HTTPS.
   PortBridge probes HTTPS through the SSH tunnel and records the upstream scheme as `https`.

2. Pretty URL is local HTTP.
   The local proxy itself currently serves HTTP on `:8088`, while forwarding to HTTP or HTTPS upstream services.

For HTTPS upstreams with self-signed dev certificates, the probe and proxy accept the certificate so local dev services work without browser trust setup on the tunnel side.

PortBridge does not currently provide trusted local HTTPS URLs like `https://p3000.devbox.localhost`. That would require local certificate generation/trust and usually a privileged port or helper for port `443`.

## SSH Behavior

PortBridge deliberately uses the system SSH binary. That means it inherits:

- `~/.ssh/config`
- SSH agent
- ProxyJump
- known hosts
- hardware keys
- whatever authentication behavior already works in your terminal

SSH scan options include:

- `BatchMode=yes`
- `ConnectTimeout=8`
- `ServerAliveInterval=15`
- `ServerAliveCountMax=2`
- `StrictHostKeyChecking=accept-new`
- `LogLevel=ERROR`

The app filters the common first-connection warning:

```text
Warning: Permanently added ...
```

## Configuration

Default config path:

```text
~/Library/Application Support/PortBridge/config.json
```

The file stores hosts, discovered services, proxy port, local tunnel port range, and service state.

Useful defaults:

```json
{
  "proxyPort": 8088,
  "localPortRangeStart": 24000,
  "localPortRangeEnd": 39999,
  "hideNonHTTPPorts": true
}
```

The UI has an `Open Config` button in the header. Changes are saved automatically with a short debounce.

## Build

```bash
swift build
```

Release build:

```bash
swift build -c release
```

## Run

From the package directory:

```bash
swift run PortBridge
```

Or run the release binary:

```bash
.build/release/PortBridge
```

The app runs as an accessory menu-bar app and appears as `PB`.

## Test

```bash
swift test
```

The test suite covers SSH config parsing, scan parsing, warning cleanup, URL/route naming, config round-tripping, HTTPS misclassification cleanup, auto-forward defaults, and hidden non-HTTP/never-forward records.

## Troubleshooting

### I do not see a service after scanning

Check whether auto-forward is enabled for the host.

If auto-forward is off, discovered ports are tracked but placed under `Disabled Ports`. Expand that section and enable the port manually.

If auto-forward is on and the service is not HTTP/HTTPS, PortBridge hides it after probing.

### A web service appears under Disabled Ports

Enable it manually. PortBridge will start a tunnel and probe it.

If probing cannot infer the service, use `HTTP` or `HTTPS` to force the route.

### Port 22 disappeared

That is intentional. SSH port `22` is in the never-forward list and is filtered from scans and legacy state.

### The pretty URL works but I do not see anything in `/etc/hosts`

That is expected for `.localhost`. Browsers and the OS resolve `*.localhost` to loopback without a hosts-file entry.

PortBridge removed hosts-file management entirely. The proxy is available at `:8088`, so pretty routes include the explicit port.

### I want the original remote port locally

PortBridge prefers the original remote port when allocating a local tunnel port, but will pick another free local port if that port is already in use. Use the raw localhost open/copy buttons to access the actual assigned local tunnel.

### The proxy does not start

Something may already be listening on port `8088`. Change `proxyPort` in the config file or stop the other process, then use the restart icon.

### HTTPS service opens as HTTP

Use the `HTTPS` force action for that port. The app also detects the common "plain HTTP request was sent to HTTPS port" response and corrects it automatically on reprobe.

## Known Limitations

- HTTP/HTTPS browser services only.
- Local proxy is HTTP, not trusted local HTTPS.
- No packaged `.app` bundle or launch-at-login helper yet.
- No privileged helper for port `80` or `443`.
- No service renaming UI yet, although the core model supports route labels.
- No custom ignore list UI yet; port `22` is currently hard-coded in the never-forward list.
- The proxy is intentionally simple and does not yet implement all production proxy edge cases such as WebSocket upgrade handling.

## Attribution

PortBridge is inspired by Cursor and `vercel-labs/portless`.
