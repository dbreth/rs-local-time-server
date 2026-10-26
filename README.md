# time-server

Minimal SNTP server for keeping the rover computes' clocks in sync with a base station computer
(fixes ROS2 cross-compute timing issues: tf2 extrapolation errors, message_filters drops, etc.).

The base station's clock becomes the reference. Rover computes poll it with the NTP client their
OS already ships (`systemd-timesyncd` or `chronyd`), so there's nothing to install on the rover.

Clients keep polling (every ~16–64 s) rather than syncing once at boot, because quartz clocks
drift apart by ~3 ms/minute — enough to break ROS2 timing within an hour.

## Base station (server)

```bash
cargo build --release
sudo install -m 755 target/release/time-server /usr/local/bin/
sudo cp time-server.service /etc/systemd/system/
sudo systemctl enable --now time-server
journalctl -u time-server -f       # should print "listening on 0.0.0.0:123"
```

Every time a device gets the time, a line is logged to stdout with its address (and NTP version, or
the HTTP request), and the first request from each IP is marked `★ new client`:

```
2026-10-25T14:03:12.481Z  INFO   NTP   10.0.20.5:123          v4  ★ new client
2026-10-25T14:04:01.117Z  INFO   HTTP  10.0.10.7:51234        GET /
```

Output is coloured in a terminal and plain under journald or when piped. Set `RUST_LOG=warn` to
hide the per-request lines, or `RUST_LOG=debug` to also see ignored (non-client) NTP packets.

Make sure UDP port 123 (NTP) and TCP port 8123 (HTTP/JSON, for `get-date.sh`) are open in the
firewall. Don't also run an NTP client on this machine
that points at itself.

For a quick manual run instead of the service:

```bash
sudo setcap cap_net_bind_service=+ep target/release/time-server
./target/release/time-server                              # NTP on 0.0.0.0:123, HTTP on 0.0.0.0:8123
./target/release/time-server 0.0.0.0:1234 0.0.0.0:8080    # custom NTP / HTTP addresses
```

### Nix / NixOS

```bash
nix build github:dbreth/rs-local-time-server     # result/bin/{time-server,get-date.sh}
nix run github:dbreth/rs-local-time-server       # run the server
```

NixOS module (opens UDP 123 / TCP 8123 by default):

```nix
{
  inputs.time-server.url = "github:dbreth/rs-local-time-server";

  outputs = { nixpkgs, time-server, ... }: {
    nixosConfigurations.base = nixpkgs.lib.nixosSystem {
      modules = [
        time-server.nixosModules.default
        {
          services.time-server.enable = true;
          # services.time-server.ntpAddress = "0.0.0.0:123";
          # services.time-server.httpAddress = "0.0.0.0:8123";
          # services.time-server.openFirewall = true;
        }
      ];
    };
  };
}
```

## One-shot sync, no configuration (`get-date.sh`)

On any machine that can reach the base station, run:

```bash
./get-date.sh BASE_IP          # or: get-date.sh BASE_IP 8123
# or, with Nix: nix run github:dbreth/rs-local-time-server#get-date -- BASE_IP
```

It fetches the time from the server's HTTP endpoint (pure bash, no curl/jq), corrects for half the
round-trip time, and sets the clock with `sudo date -s`. The endpoint just returns JSON:

```bash
$ curl BASE_IP:8123
{"unix_ns":1792208538050733711,"unix":1792208538.050733711}
```

This is a one-time set: the clock will start drifting again afterwards (~3 ms/minute), so for
anything long-running configure an NTP client as below.

## Rover computes (clients)

Replace `BASE_IP_VLAN10` / `BASE_IP_VLAN20` with the base station's IP on each radio's VLAN.
Listing both gives a fallback if one radio link drops.

### systemd-timesyncd (default on Jetson / Ubuntu / Raspberry Pi OS)

`/etc/systemd/timesyncd.conf`:

```ini
[Time]
NTP=BASE_IP_VLAN20 BASE_IP_VLAN10
FallbackNTP=
PollIntervalMinSec=16
PollIntervalMaxSec=64
```

```bash
sudo systemctl restart systemd-timesyncd
timedatectl timesync-status   # Server: should be the base station, Offset: small
```

### chronyd (if installed, e.g. some Orange Pi images — timesyncd won't run alongside it)

chrony keeps correcting for drift while the radio link is down, so it's the better choice if
the rover regularly goes out of range. Add to `/etc/chrony/chrony.conf` (comment out other
`pool`/`server` lines):

```conf
server BASE_IP_VLAN20 iburst minpoll 4 maxpoll 6
server BASE_IP_VLAN10 iburst minpoll 4 maxpoll 6
makestep 1.0 3
```

```bash
sudo systemctl restart chronyd
chronyc sources -v
chronyc tracking
```
