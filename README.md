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

Make sure UDP port 123 is open in the firewall. Don't also run an NTP client on this machine
that points at itself.

For a quick manual run instead of the service:

```bash
sudo setcap cap_net_bind_service=+ep target/release/time-server
./target/release/time-server               # binds 0.0.0.0:123 (all VLANs)
./target/release/time-server 0.0.0.0:1234  # custom address/port, no privileges needed
```

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
