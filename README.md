# xray-tun

A systemd daemon that puts **all** traffic through an Xray server via a TUN
device, like a VPN. Toggle with `xray-tun on` / `xray-tun off`.

Pure Xray — no tun2socks, no sing-box. Xray 26.3.27 ships a native `tun`
inbound (gVisor netstack), so one process terminates the IP packets and
carries them out over VLESS/REALITY.

## Requirements

* Linux with systemd and `iproute2`
* `xray` 26.x or newer — the `tun` inbound is what makes this work at all;
  check with `xray version` and `xray run -dump -c` on a config using it
* root (creating a TUN device and editing routing policy need `CAP_NET_ADMIN`)
* a VLESS server you can reach

Developed on Arch. Nothing in it is Arch-specific beyond assuming systemd
units live in `/etc/systemd/system`.

## Install

```sh
cd xray-tun
sudo ./install.sh                        # --polkit for password-free toggling
xray-tun add home 'vless://...'          # paste a share link
xray-tun on
```

Add as many servers as you like and switch with `xray-tun use`. No share
link? `sudo xray-tun edit` and fill in the `proxy` outbound in `config.json` by
hand instead.

The `proxy` outbound shipped in `etc/config.json` is a **non-functional
placeholder** (`REPLACE.WITH.YOUR.SERVER`). It parses, so the config validates,
but it cannot connect. Import a real server before `xray-tun on`.

`install.sh` never overwrites an existing `/etc/xray-tun/config.json` — it
drops the new one next to it as `config.json.new`.

Never commit anything under `servers/` or a generated `zz-server.json`: they
hold your UUID and keys. `.gitignore` already excludes them.

## Use

```
xray-tun on | off | toggle | restart
xray-tun status          # state, device, routes, DNS, exit IP
xray-tun enable | disable  # autostart at boot (off by default)
xray-tun check | edit | edit-net | logs | ip
```

Every command that reports an exit IP probes the network on a short leash
(4s, once — a broken tunnel swallows DNS too, so a longer wait buys nothing).
`XRAY_TUN_NO_IP=1` skips the probe; `XRAY_TUN_IP_TIMEOUT` changes the budget.

Servers, one profile each:

```
xray-tun add NAME URL   # add (or update) a server, and switch to it
xray-tun ls             # list them, * marks the active one
xray-tun use NAME       # switch
xray-tun rm NAME        # delete (--force if it is the active one)
xray-tun show [NAME]    # details; --show-link prints the original URL
```

```console
$ xray-tun ls
* tokyo   tokyo.example.com:443   [ws/tls]        Tokyo Node
  berlin  berlin.example.com:443  [tcp/reality]   Berlin
$ xray-tun use berlin
active profile is now 'berlin'
restarted xray-tun.service
```

Switching restarts the daemon only if it is already running, so `use` is safe
while the tunnel is down.

`on`/`off` are runtime only. `enable`/`disable` control boot autostart. They
are independent, the way systemd means them.

## Servers: `vless2xray`

`xray-tun add` wraps `vless2xray`, which turns a `vless://` share link into an
Xray outbound and files it as a named profile:

```sh
xray-tun add tokyo 'vless://uuid@host:443?type=ws&security=tls&sni=...#Tokyo'
xray-tun add 'vless://...'                # name taken from the link's #remark

vless2xray 'vless://...'                  # print the drop-in, change nothing
vless2xray --outbound 'vless://...'       # print just the outbound object
pbpaste | vless2xray -                    # read the link from stdin
```

### Quote the link

**Always put the link in single quotes.** A `vless://` URL is full of `&` and
`#`. Unquoted at a shell prompt, bash reads every `&` as "run the preceding
command in the background", so the tool receives only the text up to the first
one and the rest runs as stray jobs:

```console
$ xray-tun add tokyo vless://uuid@host:8443?path=/ws&security=tls&type=ws#Tokyo
[1] 114921
[2] 114922
[2]   Done       security=tls
[1]+  Stopped    xray-tun add tokyo vless://uuid@host:8443?path=/ws
```

The cruel part is that what survives is still a *valid* link —
`vless://uuid@host:8443?path=/ws` parses cleanly as a plain-TCP server with no
TLS and no WebSocket. It installs, it looks healthy in `ls`, and it simply
cannot connect. (The `Stopped` job is the same bug: a backgrounded command
that reaches a `sudo` password prompt is suspended by `SIGTTIN`.)

`add` now refuses a link with that signature — a single query parameter and no
`#name` — and says so before it asks for a password. If a link really is that
short, `vless2xray --install --force` accepts it.

A TLS-shaped port (443, 8443) with no `security=` also earns a warning, since
that is the other shape a mangled link takes.

### Where things live

```
/etc/xray-tun/
├── config.json          the daemon: tun inbound, routing, placeholder proxy
├── xray-tun.conf        network knobs (device, fwmark, table, DNS)
├── zz-server.json  ->   servers/tokyo.json      the ACTIVE server (a symlink)
└── servers/             one file per saved server, 0600
    ├── tokyo.json
    └── berlin.json
```

Three properties of `xray run -confdir` make that layout work. All three were
checked against the binary rather than assumed:

* **It does not recurse into subdirectories.** So `servers/` can sit inside the
  config dir and only the active profile is ever loaded — the others are inert
  files, not merged outbounds.
* **It follows symlinks.** So switching servers is one atomic relink, with
  nothing copied and no file rewritten.
* **It applies files in name order and replaces same-tag outbounds wholesale.**
  So the drop-in overrides the `proxy` placeholder in `config.json` with no
  stale transport settings surviving — swapping a REALITY server for a
  WebSocket one leaves no orphaned `realitySettings` behind.

The `zz-` prefix is load-bearing. A drop-in read *before* `config.json` gets
that file's outbounds prepended, which demotes `proxy` from being the first
outbound — and xray treats the first outbound as the default, so unmatched
traffic would quietly go out direct instead of through the tunnel. The test
suite asserts `proxy` is first for every transport.

### Safety

`add` and `use` both run the *merged* config through `xray run -dump` before
committing, so a bad link or a broken profile cannot take down a working
tunnel. Writes are atomic (temp file + rename), and profiles are `0600` under a
`0700` directory since they hold your UUID and keys.

`rm` refuses to delete the active profile unless you pass `--force`; forcing it
clears the symlink rather than leaving a dangling one, because xray aborts
reading the whole config dir if it finds one and the daemon then will not start
at all.

The store self-repairs on every command: it sweeps a stale `50-server.json`
from older versions, adopts a pre-profiles `zz-server.json` as a named profile,
and clears a dangling active symlink.

### Supported links

Transports `tcp` (incl. `headerType=http` obfs), `ws`, `grpc`,
`xhttp`/`splithttp`, `httpupgrade`, `h2`, `kcp`, `quic`; security `none`, `tls`,
`reality` (with `pbk`/`sid`/`spx`/`pqv`), and legacy `xtls` (warns, emits
`tls`); plus `flow`, `fp`, `alpn`, `allowInsecure`, `encryption`, IPv6 address
literals and percent-encoded paths.

`vmess://`, `trojan://` and `ss://` are rejected with a clear message rather
than a wrong config.

## Tests

```sh
./tests/run-tests.sh
```

No root, no network, no touching `/etc` — everything runs against a throwaway
config dir via `XRAY_TUN_CONFDIR`, and every generated config is checked by
xray's own parser rather than by what we think it should say. Needs `xray` on
`PATH`.

`XRAY_TUN_CONFDIR` also works outside the tests, if you want `vless2xray` to
manage a config tree other than the system one.

## How it works

```
apps ──▶ default route ──▶ xtun0 ──▶ xray (tun inbound, gVisor)
                                        │
                                        ├─ private IPs ──▶ direct
                                        ├─ IPv6        ──▶ blackhole
                                        └─ everything  ──▶ VLESS/REALITY ──▶ server
```

Four moving parts:

| Piece | Where | Job |
|---|---|---|
| `xray` | `/etc/xray-tun/config.json` | makes `xtun0`, terminates packets, proxies them |
| `netctl.sh` | `/usr/local/lib/xray-tun/` | address, routes, ip rules, DNS |
| `xray-tun.service` | `/etc/systemd/system/` | glues the two; `ExecStopPost` always restores routing |
| `xray-tun` | `/usr/local/bin/` | the on/off switch |

### The loop problem, and the fix

If *everything* goes into the tunnel, xray's own connection to the server
goes into the tunnel too, and the tunnel eats itself.

The fix is an fwmark, not a hardcoded route to the server IP:

* every outbound carries `streamSettings.sockopt.mark = 255`, so xray stamps
  its own sockets;
* the default route into `xtun0` lives in routing table **8888**, not `main`;
* two rules, in priority order:

  ```
  ip rule add     fwmark 255 lookup main pref 7080   # xray's own traffic
  ip rule add not fwmark 255 lookup 8888 pref 7100   # everything else
  ```

The first one matters more than it looks. Letting marked packets merely *fall
through* past 7100 is not enough — any other VPN client with a catch-all rule
of its own will swallow them on the way down (sing-box installs
`from all lookup <table>` around pref 9001, and it does not filter on fwmark),
and your server connection ends up inside someone else's tunnel. Claiming
`main` explicitly, at the lowest priority number we use, settles it.

Marked packets therefore leave via the real interface. This
keeps working when your server IP changes, when you have several servers, and
when you roam between networks — none of which a pinned host route survives.

Priority 7090 sits above it and keeps LAN, loopback and multicast on `main`,
so your router, printer and SSH-to-a-box-on-the-couch still work.

### DNS

While the tunnel is up, `/etc/resolv.conf` is replaced with `1.1.1.1` /
`8.8.8.8`. Those are public addresses, so the queries go into the TUN and out
through the server instead of to your LAN router — no leak. The original file
is snapshotted in `/run/xray-tun/` and restored on stop.

NetworkManager will rewrite `resolv.conf` if you change network connection
while the tunnel is up; `xray-tun restart` puts it back. Set `MANAGE_DNS=0`
in `xray-tun.conf` if you'd rather handle DNS yourself.

### IPv6

Default is `IPV6_MODE=block`: v6 is blackholed in table 8888 and `::/0` goes
to the `block` outbound, so apps fail over to IPv4 immediately rather than
hanging. No v6 leak.

If your server speaks IPv6, set `IPV6_MODE=tunnel` in `xray-tun.conf` **and**
delete the `"ip": ["::/0"] → block` rule from `config.json`.

`IPV6_MODE=leave` does not touch v6 at all — that leaks, and is only there for
debugging.

## Tuning

`/etc/xray-tun/config.json` — the server, and Xray routing rules.
`/etc/xray-tun/xray-tun.conf` — device name, addresses, fwmark, table,
rule priorities, IPv6 mode, DNS, bypass subnets.

`TUN_NAME` and `TUN_MTU` appear in both files and must agree. So must
`FWMARK` and `sockopt.mark`.

Run `xray-tun check` after editing; `ExecStartPre` also validates with
`xray run -dump`, so a typo fails the unit instead of half-configuring your
routing.

## Notes and caveats

* **Not a kill switch.** If xray dies, `ExecStopPost` tears the routes down
  and traffic goes out direct. `Restart=on-failure` retries first. If you want
  fail-closed instead, replace the `down` teardown with a blackhole default in
  table 8888.
* **It runs as root.** Creating a TUN device, editing routing policy and
  setting `SO_MARK` all need `CAP_NET_ADMIN`.
* **One tunnel at a time.** The stock `xray.service` (SOCKS on 8080/10809) can
  coexist — this daemon uses its own config dir and port 10808. But a GUI
  client (Hiddify, Happ, sing-box) holding its own TUN will fight it: those
  install catch-all policy rules that do not filter on fwmark, so they capture
  even xray's own marked server connection. Quit them before `xray-tun on`.
  `xray-tun status` prints a `conflict` line when it detects one.
* The local SOCKS5 on `127.0.0.1:10808` is there for testing the outbound
  without the TUN: `curl --socks5-hostname 127.0.0.1:10808 https://api.ipify.org`.

## Troubleshooting

`xray-tun status` says running, but `exit ip` is `unreachable`.

**0. Is the link intact?** `xray-tun show` — if `transport` says `tcp` and
`security` says `none` on a server you know uses WebSocket or TLS, the link was
truncated by the shell. Re-add it in single quotes; `add` updates in place.

**1. Is it the server, or the routing?** `xray-tun on` now answers this for you
when the exit IP comes back unreachable. By hand:

```sh
curl --socks5-hostname 127.0.0.1:10808 https://api.ipify.org
```

Prints an IP → the server is fine, the problem is routing; go to step 2.
Hangs → the server or the link is wrong, and no routing work will help.

**2. Is another VPN stealing the marked packets?**

```sh
ip route get 1.1.1.1 mark 255
```

This must leave via your **real** interface (`wlan0`, `eth0`). If it says
`dev tun0` or any other tunnel, something else is capturing xray's own server
connection — quit that client and restart.

**3. Are packets reaching xray at all?**

```sh
sudo journalctl -u xray-tun -f
```

Lines like `accepted udp:1.1.1.1:53 [tun-in -> proxy]` mean the TUN half works
and the failure is downstream, in the outbound. No such lines mean traffic is
not entering the tunnel; check `ip rule show` and `ip route show table 8888`.

**4. Is the right server active, and did the drop-in lose to config.json?**

```sh
xray-tun ls          # * marks the active profile
```



```sh
sudo xray run -dump -confdir /etc/xray-tun | grep -m1 -A2 outbounds
```

The first outbound must be `proxy`. `-confdir` applies files in name order, so
a drop-in sorting before `config.json` gets that file's outbounds prepended and
silently demotes `proxy`. That is why the generated file is `zz-server.json`.

## Uninstall

```sh
sudo ./uninstall.sh      # leaves /etc/xray-tun alone
```
