#!/usr/bin/env bash
# tests/run-tests.sh -- offline tests for vless2xray. No root, no network,
# no touching /etc: every case runs against a throwaway config dir via
# XRAY_TUN_CONFDIR. Needs `xray` on PATH, because the point is to check what
# xray itself makes of the output rather than what we think it should.
set -u
cd "$(dirname "$0")/.." || exit 1
SRC=$PWD
V=$SRC/bin/vless2xray
pass=0; fail=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v xray >/dev/null || { echo "xray not on PATH; cannot run tests"; exit 1; }

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2', want '$3'"; }

# ---------------------------------------------------------------- transports
# Each link must convert, merge cleanly, and leave `proxy` FIRST -- xray takes
# the first outbound as the default, so an ordering slip silently sends
# unmatched traffic out direct instead of through the tunnel.
transport() {
    local name="$1" link="$2" want="$3"
    local d="$WORK/t$RANDOM$RANDOM"; mkdir -p "$d"
    cp "$SRC/etc/config.json" "$d/config.json"
    if ! "$V" "$link" > "$d/zz-server.json" 2>"$d/err"; then
        bad "$name" "$(head -1 "$d/err")"; return
    fi
    local out
    if ! out=$(xray run -dump -confdir "$d" 2>&1); then
        bad "$name" "xray rejected it: $(printf '%s' "$out" | tail -1)"; return
    fi
    local got
    got=$(printf '%s' "$out" | grep -v '^Xray \|^A unified' | python3 -c "
import sys, json
d = json.load(sys.stdin)
tags = [x['tag'] for x in d['outbounds']]
if tags[0] != 'proxy':
    print('ORDER:' + ','.join(tags)); raise SystemExit
s = [x for x in d['outbounds'] if x['tag'] == 'proxy'][0]['streamSettings']
print('%s/%s/%s' % (s.get('network'), s.get('security'),
                    s.get('sockopt', {}).get('mark')))")
    is "$name" "$got" "$want"
}

echo "transports:"
transport "ws+tls"        'vless://1111-2222@a.example.com:443?type=ws&security=tls&sni=a.example.com&path=%2Fwsx%3Fed%3D2048&host=cdn.example.com&fp=firefox&alpn=h2,http%2F1.1#ws' "ws/tls/255"
transport "grpc+reality"  'vless://1111-2222@b.example.com:443?type=grpc&security=reality&sni=b.example.com&pbk=ABCdefGHI_jklMNOpqrSTUvwxYZ0123456789abcd&sid=aabb&serviceName=svc&mode=multi#grpc' "grpc/reality/255"
transport "xhttp"         'vless://1111-2222@c.example.com:443?type=xhttp&security=tls&sni=c.example.com&path=%2Fyy&mode=packet-up#xhttp' "xhttp/tls/255"
transport "httpupgrade"   'vless://1111-2222@d.example.com:80?type=httpupgrade&security=none&path=%2Fhu&host=d.example.com#hu' "httpupgrade/none/255"
transport "h2+tls"        'vless://1111-2222@e.example.com:443?type=http&security=tls&sni=e.example.com&path=%2Fh2&host=e1.example.com,e2.example.com#h2' "h2/tls/255"
transport "kcp"           'vless://1111-2222@f.example.com:2000?type=kcp&security=none&headerType=wechat-video&seed=pw#kcp' "kcp/none/255"
transport "quic"          'vless://1111-2222@g.example.com:443?type=quic&security=tls&sni=g.example.com&quicSecurity=aes-128-gcm&key=kk&headerType=srtp#quic' "quic/tls/255"
transport "tcp+http-obfs" 'vless://1111-2222@h.example.com:80?type=tcp&security=none&headerType=http&host=www.example.com&path=%2Fabc#obfs' "tcp/none/255"
transport "plain tcp"     'vless://1111-2222@i.example.com:1234#plain' "tcp/none/255"
transport "ipv6 literal"  'vless://1111-2222@[2001:db8::1]:443?type=tcp&security=tls&sni=v6.example.com#v6' "tcp/tls/255"
transport "vision+reality" 'vless://1111-2222@j.example.com:443?type=tcp&security=reality&sni=j.example.com&pbk=ABCdefGHI_jklMNOpqrSTUvwxYZ0123456789abcd&sid=df31&flow=xtls-rprx-vision#vision' "tcp/reality/255"

# ------------------------------------------------------------------- rejects
echo "rejected links:"
rejects() {
    local name="$1" link="$2"
    if "$V" --outbound "$link" >/dev/null 2>&1; then
        bad "$name" "was accepted, should have been refused"
    else ok "$name"; fi
}
rejects "vmess://"          'vmess://eyJhZGQiOiJ4In0='
rejects "trojan://"         'trojan://pw@h.example.com:443'
rejects "not a proxy link"  'https://example.com'
rejects "no uuid"           'vless://@h.example.com:443'
rejects "no port"           'vless://u@h.example.com'
rejects "reality w/o pbk"   'vless://u@h.example.com:443?security=reality&sni=x'

# ------------------------------------------------------------------ decoding
echo "decoding:"
got=$("$V" --outbound 'vless://1111-2222@a.example.com:443?type=ws&security=tls&sni=a.example.com&path=%2Fwsx%3Fed%3D2048&host=cdn.example.com&alpn=h2%2Chttp%2F1.1&allowInsecure=1' 2>/dev/null | python3 -c "
import sys, json
s = json.load(sys.stdin)['streamSettings']
print('%s|%s|%s|%s' % (s['wsSettings']['path'], s['wsSettings']['host'],
                       ','.join(s['tlsSettings']['alpn']),
                       s['tlsSettings'].get('allowInsecure')))")
is "percent-encoding, alpn, insecure" "$got" "/wsx?ed=2048|cdn.example.com|h2,http/1.1|True"

# ------------------------------------------------------------------ profiles
echo "profiles:"
CT=$WORK/conf; mkdir -p "$CT"
cp "$SRC/etc/config.json" "$SRC/etc/xray-tun.conf" "$CT/"
export XRAY_TUN_CONFDIR=$CT
active() { basename "$(readlink "$CT/zz-server.json" 2>/dev/null)" .json 2>/dev/null; }
server() { xray run -dump -confdir "$CT" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print([o for o in d['outbounds'] if o['tag']=='proxy'][0]['settings']['vnext'][0]['address'])"; }

"$V" --install --name alpha 'vless://1111@alpha.example.com:2443?type=tcp&security=none' >/dev/null
"$V" --install --name beta  'vless://2222@beta.example.com:443?type=ws&security=tls&sni=beta.example.com' >/dev/null
is "add activates the newest"  "$(active)" "beta"
is "xray uses the active one"  "$(server)" "beta.example.com"
is "only active one is merged" "$(xray run -dump -confdir "$CT" 2>/dev/null | grep -c '"tag": "proxy"')" "1"

"$V" --use alpha >/dev/null
is "use switches"              "$(active)" "alpha"
is "xray follows the switch"   "$(server)" "alpha.example.com"

"$V" --install --name alpha 'vless://9999@alpha2.example.com:2443?type=tcp&security=none' >/dev/null
is "re-add updates in place"   "$(server)" "alpha2.example.com"
is "re-add keeps it active"    "$(active)" "alpha"

"$V" --remove beta >/dev/null
is "rm inactive keeps active"  "$(active)" "alpha"
"$V" --remove alpha >/dev/null 2>&1
is "rm refuses the active one" "$(active)" "alpha"
"$V" --remove alpha --force >/dev/null 2>&1
is "rm --force clears active"  "$(active)" ""
xray run -dump -confdir "$CT" >/dev/null 2>&1 \
    && ok "xray still starts with no profile" \
    || bad "xray still starts with no profile" "confdir broke"

echo "dns caching:"
# The shipped config must answer from cache, and must not make AAAA or
# HTTPS/type-65 queries hang -- browsers ask for both on every domain, and a
# resolver that swallows them is slower than having no resolver at all.
# xray -dump strips the // comments and applies defaults, so this inspects
# what xray really builds rather than what the file appears to say.
dns_cfg=$WORK/dns-dump.json
xray run -dump -c "$SRC/etc/config.json" > "$dns_cfg" 2>/dev/null
if [ -s "$dns_cfg" ]; then
    has_rule=$(python3 -c "
import json,sys
d=json.load(open('$dns_cfg'))
print(any(r.get('outboundTag')=='dns-out' for r in d['routing']['rules']))")
    is "dns hijack rule present" "$has_rule" "True"
    has_out=$(python3 -c "
import json
d=json.load(open('$dns_cfg'))
print(any(o.get('tag')=='dns-out' for o in d['outbounds']))")
    is "dns outbound present" "$has_out" "True"
    strat=$(python3 -c "
import json
print(json.load(open('$dns_cfg'))['dns'].get('queryStrategy'))")
    is "queries IPv4 only (v6 is blackholed)" "$strat" "UseIPv4"
    blocked=$(python3 -c "
import json
o=[x for x in json.load(open('$dns_cfg'))['outbounds'] if x.get('tag')=='dns-out'][0]
print('blockTypes' in o.get('settings', {}))")
    is "no blockTypes (it makes AAAA time out)" "$blocked" "False"
else
    bad "dns config dump" "xray could not dump etc/config.json"
fi

echo "bad names:"
for n in '../evil' '/etc/passwd' 'a/b' '.hidden'; do
    if "$V" --install --name "$n" 'vless://4444@x.example.com:2443?type=tcp' >/dev/null 2>&1
    then bad "rejects $n" "accepted"; else ok "rejects $n"; fi
done

echo "shell-truncated links:"
# Unquoted at a prompt, bash cuts a vless:// link at the first & -- and what
# survives still parses, as a plain-TCP server that cannot connect. These
# assert we refuse it instead of storing something that looks healthy.
refuses() {
    if "$V" --install --name trunc "$2" >/dev/null 2>&1
    then bad "$1" "accepted a truncated link"; else ok "$1"; fi
}
accepts() {
    if "$V" --install --name fine "$2" >/dev/null 2>&1
    then ok "$1"; else bad "$1" "refused a good link"; fi
}
refuses "refuses a cut link"        'vless://u@h.example.com:8443?path=%2Fws'
accepts "accepts a full link"       'vless://u@h.example.com:8443?path=%2Fws&security=tls&type=ws#Real'
accepts "accepts one param + #name" 'vless://u@h.example.com:2443?encryption=none#Named'
accepts "accepts a bare link"       'vless://u@h.example.com:2443'
if "$V" --install --name forced --force 'vless://u@h.example.com:8443?path=%2Fws' >/dev/null 2>&1
then ok "--force overrides the guard"; else bad "--force overrides the guard" "still refused"; fi

# and the wrapper catches it before sudo, which matters: an unquoted command is
# backgrounded, and a background job that hits a password prompt is stopped by
# SIGTTIN before it can print anything.
if bin/xray-tun add trunc 'vless://u@h.example.com:8443?path=%2Fws' >/dev/null 2>&1
then bad "wrapper catches it pre-sudo" "accepted"; else ok "wrapper catches it pre-sudo"; fi

echo "latency check:"
# The ping must never fire in a non-system config dir: tests are offline, and
# a switch should not block on the network just because someone pointed
# XRAY_TUN_CONFDIR at a scratch tree.
# Match on the measurement itself ("... ms to server" / "... ms through it"),
# never on the word "ping" -- a profile name can contain that.
measured() { case "$1" in *" ms to server"*|*" ms through it"*|*"could not measure"*) return 0 ;; esac; return 1; }

for n in lat-a lat-b; do
    XRAY_TUN_CONFDIR=$CT "$V" --install --name "$n" \
        "vless://1111@$n.example.com:8443?type=ws&security=tls&sni=$n.example.com&path=%2Fw#$n" \
        >/dev/null 2>&1
done
out=$(XRAY_TUN_CONFDIR=$CT timeout 15 "$V" --use lat-a 2>&1)
case "$out" in *"active profile is now"*) : ;; *) bad "switch happened" "$out" ;; esac
if measured "$out"; then
    bad "no latency check outside the system confdir" "measured anyway: $out"
else
    ok "no latency check outside the system confdir"
fi
out=$(XRAY_TUN_CONFDIR=$CT XRAY_TUN_NO_PING=1 timeout 15 "$V" --ping lat-a 2>&1)
if measured "$out"; then
    bad "XRAY_TUN_NO_PING silences it" "still printed: $out"
else
    ok "XRAY_TUN_NO_PING silences it"
fi
# A healthy-but-unreadable profile must not be mistaken for a dangling link:
# servers/ is 0700, so exists() lies to an unprivileged caller.
CT=$CT probe=$(CT=$CT python3 - <<'PY2'
import os, sys
sys.argv = ["x"]
src = open("bin/vless2xray").read().replace('if __name__ == "__main__":', 'if False:')
m = type(sys)("m"); m.__dict__["__name__"] = "m"
os.environ["XRAY_TUN_CONFDIR"] = os.environ["CT"]
exec(compile(src, "v", "exec"), m.__dict__)
link = os.path.join(os.environ["CT"], "zz-server.json")
print("missing" if m.dropin_target_missing() else "present")
PY2
)
CT=$CT is "a readable profile is not 'dangling'" "$probe" "present"

echo "self-repair:"
"$V" --install --name gamma 'vless://5555@gamma.example.com:2443?type=tcp&security=none' >/dev/null
rm -f "$CT/servers/gamma.json"                     # dangling symlink
"$V" --list >/dev/null 2>&1
xray run -dump -confdir "$CT" >/dev/null 2>&1 \
    && ok "heals a dangling active symlink" \
    || bad "heals a dangling active symlink" "xray cannot start"

printf '{"outbounds":[]}' > "$CT/50-server.json"    # stale pre-zz drop-in
"$V" --list >/dev/null 2>&1
[ -e "$CT/50-server.json" ] \
    && bad "sweeps stale 50-server.json" "still there" \
    || ok "sweeps stale 50-server.json"

# --------------------------------------------------------------- menus
# The pickers and prompts only exist when there is a real terminal, so these
# run the tool under a pseudo-terminal and type at it.
echo "interactive menus:"
TUI=$WORK/tui; mkdir -p "$TUI"
cp "$SRC/etc/config.json" "$SRC/etc/xray-tun.conf" "$TUI/"
for n in aaa bbb ccc; do
    XRAY_TUN_CONFDIR=$TUI "$V" --install --name "$n" \
        "vless://1111-2222@$n.example.com:8443?type=ws&security=tls&sni=$n.example.com&path=%2Fws#$n node" \
        >/dev/null 2>&1
done
drive() { python3 "$SRC/tests/drive_tty.py" "$TUI" "$1" -- "$V" "${@:2}"; }
active_tui() { basename "$(readlink "$TUI/zz-server.json" 2>/dev/null)" .json 2>/dev/null; }

# ccc is active and the cursor starts on it; one "up" lands on bbb.
drive "up,\r" --use >/dev/null 2>&1
is "arrow keys select"      "$(active_tui)" "bbb"
drive "s,\r" --use >/dev/null 2>&1
is "w/s also move"          "$(active_tui)" "ccc"
drive "1" --use >/dev/null 2>&1
is "digits jump"            "$(active_tui)" "aaa"
drive "down,q" --use >/dev/null 2>&1
is "q cancels"              "$(active_tui)" "aaa"
drive "esc" --use >/dev/null 2>&1
is "esc cancels"            "$(active_tui)" "aaa"
case "$(drive "down,\r" --use 2>&1)" in
    *"active profile is now"*) ok "picker reports the switch" ;;
    *) bad "picker reports the switch" "no confirmation printed" ;;
esac

# Typed at our own prompt, a link with & arrives whole -- the shell, which is
# what breaks an unquoted paste, is not in the path at all.
out=$(drive 'vless://1111@tui.example.com:8443?type=ws&security=tls&sni=tui.example.com&path=%2Fws#Typed,\r,\r' --install 2>&1)
case "$out" in
    *"added profile 'Typed'"*) ok "interactive add keeps & intact" ;;
    *) bad "interactive add keeps & intact" "$(printf '%s' "$out" | tail -1)" ;;
esac
case "$out" in
    *"ws"*"tls"*) ok "add shows a summary before saving" ;;
    *) bad "add shows a summary before saving" "no summary" ;;
esac
case "$(drive '\r' --install 2>&1)" in
    *cancelled*) ok "blank link cancels the add" ;;
    *) bad "blank link cancels the add" "did not cancel" ;;
esac

# Deleting from the menu confirms first, and offers a replacement after.
before=$(XRAY_TUN_CONFDIR=$TUI "$V" --list 2>/dev/null | wc -l)
case "$(drive "down,\r,n,\r" --remove 2>&1)" in
    *delete*) ok "remove asks before deleting" ;;
    *) bad "remove asks before deleting" "no confirmation prompt" ;;
esac
is "answering no keeps it" "$(XRAY_TUN_CONFDIR=$TUI "$V" --list 2>/dev/null | wc -l)" "$before"
drive "down,\r,y,\r" --remove >/dev/null 2>&1
is "answering yes deletes" "$(XRAY_TUN_CONFDIR=$TUI "$V" --list 2>/dev/null | wc -l)" "$((before - 1))"

# With no terminal there is nothing to draw on: say so, never hang.
if timeout 5 "$V" --use </dev/null >/dev/null 2>&1; then
    bad "no-tty --use exits" "should have failed"
else
    rc=$?
    [ "$rc" -eq 124 ] && bad "no-tty --use exits" "hung until timeout" \
                      || ok "no-tty --use exits cleanly"
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
