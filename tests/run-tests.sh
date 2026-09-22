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

"$V" --install --name alpha 'vless://1111@alpha.example.com:443?type=tcp&security=none' >/dev/null
"$V" --install --name beta  'vless://2222@beta.example.com:443?type=ws&security=tls&sni=beta.example.com' >/dev/null
is "add activates the newest"  "$(active)" "beta"
is "xray uses the active one"  "$(server)" "beta.example.com"
is "only active one is merged" "$(xray run -dump -confdir "$CT" 2>/dev/null | grep -c '"tag": "proxy"')" "1"

"$V" --use alpha >/dev/null
is "use switches"              "$(active)" "alpha"
is "xray follows the switch"   "$(server)" "alpha.example.com"

"$V" --install --name alpha 'vless://9999@alpha2.example.com:443?type=tcp&security=none' >/dev/null
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

echo "bad names:"
for n in '../evil' '/etc/passwd' 'a/b' '.hidden'; do
    if "$V" --install --name "$n" 'vless://4444@x.example.com:443?type=tcp' >/dev/null 2>&1
    then bad "rejects $n" "accepted"; else ok "rejects $n"; fi
done

echo "self-repair:"
"$V" --install --name gamma 'vless://5555@gamma.example.com:443?type=tcp&security=none' >/dev/null
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

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
