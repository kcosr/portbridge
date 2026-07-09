# PortBridge

PortBridge is a native macOS menu-bar app for exposing HTTP and HTTPS services that are listening on remote SSH hosts as local browser URLs.

It is intended for dev containers, VMs, and remote workstations where services bind to the remote host's `localhost`.

## What It Does

- Imports host aliases from `~/.ssh/config`
- Allows manual SSH host entries
- Enables and disables hosts from the menu bar
- Enables and disables automatic forwarding per host, defaulting off
- Scans each enabled host for listening TCP ports
- Creates local SSH forwards with automatic local port allocation
- Probes forwarded ports for HTTP and HTTPS
- Registers browser routes such as `http://p3000.devbox.localhost:8088`
- Supports upstream HTTP and HTTPS, including self-signed dev certificates
- Provides Open, Copy URL, Force HTTP Route, and Disable Forward actions per service
- Hides ports that do not respond as HTTP or HTTPS

## Build

```bash
swift build
```

## Run

```bash
swift run PortBridge
```

The app appears in the macOS menu bar as `PortBridge`.

## Workflow

1. Choose `Import ~/.ssh/config Hosts` or `Add Host...`.
2. Enable a host.
3. PortBridge runs a remote scan using `ssh` and `ss`, `netstat`, or `lsof`.
4. Detected ports are forwarded locally and probed.
5. Browser services appear under the host menu with an Open action.

By default the local reverse proxy listens on port `8088`, so routes look like:

```text
http://p3000.devbox.localhost:8088
```

## Notes

PortBridge deliberately uses the system `ssh` binary. That means it inherits your existing SSH config, SSH agent, ProxyJump, known hosts, and hardware-key behavior.

The current proxy is HTTP on the local side and can forward to either HTTP or HTTPS upstream services through the SSH tunnel. Binding local port `80` or `443` requires a privileged helper or launch daemon; the app exposes the proxy port explicitly instead of silently requiring root.
