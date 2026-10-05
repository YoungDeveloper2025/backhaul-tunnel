# Backhaul Tunnel Manager

An interactive Bash manager for setting up and managing [Musixal/Backhaul](https://github.com/Musixal/Backhaul) tunnels between an Iran server and a server outside Iran.

Repository: [YoungDeveloper2025/backhaul-tunnel](https://github.com/YoungDeveloper2025/backhaul-tunnel)

The manager uses English menus, supports `tcp` and `tcpmux`, and installs the pinned Backhaul release **v0.7.2** with SHA256 verification.

## Server roles

| Location | Backhaul role | Purpose |
| --- | --- | --- |
| Iran | `server` | Listens on the Backhaul connection port and exposes the service ports. |
| Outside Iran | `client` | Connects to the Iran server and forwards traffic to the destination services. |

The destination application or proxy must already be running on the outside server, or at the destination IP specified in a port mapping. This script installs Backhaul; it does not install the destination application.

## Requirements

- Ubuntu with `systemd` running.
- `amd64` (`x86_64`) or `arm64` (`aarch64`) architecture.
- Root privileges through `sudo` or a root account.
- An interactive SSH terminal for the menu.
- Access to Ubuntu package repositories and GitHub from both servers.
- Available listening ports on the Iran server and the necessary firewall rules.

For remote setup from the outside server, the Iran server must also accept root SSH login using a password or keyboard-interactive authentication. The built-in SSH workflow does not use SSH keys.

## Download and run

Save `backhaul-manager.sh` in the root of this repository on the `main` branch. Download it to the server and run:

```bash
curl -fSL https://raw.githubusercontent.com/YoungDeveloper2025/backhaul-tunnel/main/backhaul-manager.sh -o backhaul-manager.sh &&
sudo bash backhaul-manager.sh
```

If `curl` is not installed:

```bash
sudo apt-get update && sudo apt-get install -y curl ca-certificates
```

The manager installs its remaining dependencies automatically. Each normal launch updates the package list and checks dependencies before opening the menu. It reuses an installed Backhaul binary when its version and stored archive checksum match.

To open the manager again from the directory containing the downloaded file:

```bash
sudo bash backhaul-manager.sh
```

For help:

```bash
bash backhaul-manager.sh --help
```

Download the file before running it: the script needs its own file path for remote installation.

## Set up both servers from the outside server

1. Run the manager on the **outside server**.
2. Choose `1) Create tunnel`.
3. Choose `2: Outside (client)`.
4. Choose `1: Automatic`.
5. Enter a tunnel name.
6. Choose `tcp` or `tcpmux`. The default is `tcpmux`.
7. Enter the **Backhaul connection port**. This question appears immediately after transport selection. Press Enter to use **3080**.
8. Enter the service ports or port mappings.
9. Enter the Iran server IP address.
10. After the local client is created, answer `y` to `Create the tunnel on the Iran server via SSH now?`.
11. Enter the Iran server SSH IP, SSH port (default `22`), and root password.

The manager copies the matching configuration to Iran, installs the server service, and tests the connection. The SSH management IP may differ from the IP used for the Backhaul connection.

Close any open manager menu on Iran before starting remote installation. Only one manager instance can run per server.

The SSH password is visible while typing. If remote setup fails, the local client configuration remains available for retrying or pairing manually.

## Set up each server separately

### On the outside server

1. Choose `Create tunnel`, then `Outside (client)`.
2. Choose `Automatic` for generated credentials and default pool settings, or `Manual` to enter those settings yourself.
3. Enter the tunnel name, transport, connection port, service ports, and Iran server IP.
4. In manual mode, enter the shared token and connection pool size. For `tcpmux`, also enter `mux_con`.
5. Copy the displayed pairing code.
6. Answer `n` when asked to install the Iran side through SSH.

### On the Iran server

1. Download and run the same manager.
2. Choose `Create tunnel`, then `1: Iran (server)`.
3. Paste the pairing code when prompted.

The code supplies the matching server configuration. It contains the shared token and is Base64-encoded, not encrypted; keep it private.

Alternatively, press Enter at the pairing-code prompt and enter the settings manually. Use the same transport, connection port, and shared token on both sides. Leaving the token blank independently on both servers generates different tokens; use the pairing code or explicitly enter the same token.

Choosing `Manual` on the outside server changes which configuration questions are asked. It still offers SSH installation afterward.

## Configuration defaults

| Setting | Default | Notes |
| --- | --- | --- |
| Tunnel name | `mytunnel` | 1-32 letters, digits, hyphens, or underscores; must begin with a letter or digit. |
| Transport | `tcpmux` | Accepted values: `tcp`, `tcpmux`. |
| Backhaul connection port | `3080` | Asked in both automatic and manual modes; edits retain the existing port as the default. |
| Service ports | `443,2083,2053,1115,1117` | Replace this list with the ports your services actually use. |
| Shared token | Generated automatically | Manual tokens must contain 16-128 letters, digits, hyphens, or underscores. |
| `connection_pool` | `8` | Configurable in manual mode; range `1-128`. |
| `mux_con` | `8` | Configurable in manual mode for `tcpmux`; range `1-128`. |
| SSH port | `22` | Used only for remote setup. |

The Iran server address must be an IPv4 or IPv6 address, not a domain name. The manager accepts ports from `1` through `65535` and rejects duplicate service listening ports.

## Port mappings

Separate mappings with commas. The left side is the listening port on the Iran server; the right side is the destination reached from the outside server.

Use individual ports or explicit IP destinations; port ranges and arbitrary destination hostnames are not accepted. `localhost` is also accepted as a destination host.

| Input | Result |
| --- | --- |
| `443` | Iran port `443` forwards to outside port `443`. |
| `443=8443` | Iran port `443` forwards to outside port `8443`. |
| `2083=127.0.0.1:2083` | Iran port `2083` forwards to `127.0.0.1:2083` on the outside server. |
| `2053=192.0.2.10:2053` | Iran port `2053` forwards to a destination IP reachable from the outside server. Replace this example IP. |

Example:

```text
443=8443,2083=127.0.0.1:2083
```

The **Backhaul connection port is separate from the service ports**. For example, `3080` can carry the Backhaul connection while `443` and `2083` are exposed to users. The script rejects a connection port that is also listed as a service listening port.

## Firewall and port availability

| Location | Required access |
| --- | --- |
| Iran | Inbound TCP to the Backhaul connection port from the outside server. |
| Iran | Inbound TCP to the selected service listening ports from their users. |
| Iran | Inbound SSH from the outside server when using remote setup. |
| Outside | Outbound TCP to the Iran Backhaul connection port and access to destination services. |

Apply the necessary rules in both the operating-system firewall and the hosting provider firewall. The script prints the relevant ports but does not change firewall rules.

Listening ports on Iran must be available. If another process already uses a selected port, choose a different one. When creating additional tunnels on the same Iran server, assign distinct connection ports and non-overlapping service listening ports; new tunnels always suggest `3080` until you enter another value.

## Manage tunnels

Choose `2) Manage existing tunnels`, select a tunnel, then choose an action:

| Menu | Action |
| --- | --- |
| `1) Edit tunnel` | Change settings; a client-side edit can also update Iran through SSH. |
| `2) Delete tunnel` | Stop and remove the selected tunnel on the current server. |
| `3) Status and logs` | Show the service status and recent logs. |
| `4) Restart` | Restart the selected service. |
| `5) Test connection` | Restart the selected service and check connection/authentication. |
| `6) Show pairing code` | Display the matching Iran configuration code. |
| `0) Back` | Return to the main menu. |

Services are enabled to start after reboot and configured to restart automatically. A connection test briefly interrupts the selected tunnel because it restarts that service; it checks fresh logs and a live control socket. Client-side tests also check whether destination services accept TCP connections.

A successful control-channel test does not prove that the full application works. Unreachable destinations are reported separately and do not change an otherwise successful control-channel result.

Changes to the transport, shared token, connection port, or Iran address must be coordinated on both sides. Deletion affects only the current server; run the manager on the other server to remove its side too. Deleting a tunnel leaves the manager script and shared Backhaul binary installed.

Port mappings take effect in the Iran server configuration. After changing them on the outside client, update Iran through SSH or the edit menu as well.

## Files and service commands

| Item | Location |
| --- | --- |
| Backhaul binary | `/opt/backhaul-manager/bin/v0.7.2/backhaul` |
| Tunnel metadata | `/etc/backhaul-manager/tunnels/<name>/metadata.json` |
| Backhaul configuration | `/etc/backhaul-manager/tunnels/<name>/config.toml` |
| Systemd unit | `/etc/systemd/system/backhaul-manager-<name>.service` |
| Rollback backups during changes | `/etc/backhaul-manager/backups/` |

The manager backs up existing configurations during changes and attempts to restore them if installation fails. Successful changes remove their rollback backup. Use the edit menu to keep metadata and generated configuration aligned.

For a tunnel named `mytunnel`:

```bash
sudo systemctl status backhaul-manager-mytunnel.service --no-pager
sudo journalctl -u backhaul-manager-mytunnel.service -n 50 --no-pager
sudo systemctl restart backhaul-manager-mytunnel.service
```

## Troubleshooting

| Message or symptom | What to check |
| --- | --- |
| `curl: (3) URL using bad/illegal format or missing URL` | Replace an older manager with this version. It keeps `BACKHAUL_VERSION` separate from Ubuntu's OS version metadata. |
| `No VM guests are running outdated hypervisor (qemu) binaries on this host.` | This package-maintenance message is informational, not a Backhaul error. |
| Port already in use | Check listeners with `sudo ss -ltnp`, then choose an available port. |
| SSH login failed | Check the SSH IP, port, password, firewall, and root login permissions. Use separate-server setup if password login is unavailable. |
| Connection could not be verified | Check both services, the shared token, transport, Iran IP, connection port, firewall rules, and logs. |
| Destination service is inactive or unreachable | Start the destination application and verify the mapping's destination address and port. |
| Another manager instance is running | Close the other manager session before starting a new one on that host. |
| SHA256 verification failed | Download was rejected. Check access to the official release and retry without bypassing verification. |

## Upstream

This repository provides a management script for [Musixal/Backhaul](https://github.com/Musixal/Backhaul). Backhaul binaries are downloaded from the upstream project's release assets. The manager is pinned to [v0.7.2](https://github.com/Musixal/Backhaul/releases/tag/v0.7.2); downloading a newer copy of the manager does not by itself select the latest upstream release.
