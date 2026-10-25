#!/usr/bin/env bash
# ============================================================================
#  update-sixdegrees-payments.sh
#
#  ONE script that keeps the SixDegrees subscription settings and the shared
#  p2p-service-backend in step:
#
#   1. ADDRESS   Reads the operator payout address that Ajo/Scrowit already use FROM YOUR LIVE
#                BACKEND, and trusts it only if (a) the Ed25519 signature verifies against
#                keys/service_wallet_public.pem, (b) the response is fresh, and (c) it is a valid
#                Monero address (base58 + Keccak checksum) on the right network. Nothing is
#                guessed or hard-coded; a typo or placeholder is rejected.
#   2. PRICES    Fixed XMR amounts (defaults: Mid 0.004, Deep 0.01 per 30 days ~ US$2 / US$5),
#                or computed from a USD target with --usd-mid/--usd-deep/--xmr-usd.
#   3. VARIABLES Writes SUBSCRIPTION_XMR_ADDRESS, SUBSCRIPTION_PRICE_{MID,DEEP}_XMR and
#                SUBSCRIPTION_PERIOD_DAYS into SixDegrees' local.properties (other lines untouched).
#   4. SERVICES  Registers SixDegrees in the backend (KNOWN_APPS, .env.example, README) and, with
#                --deploy, sets the Fly secrets, deploys, and re-verifies the live signed response.
#
#  PRIVACY NOTE: the SixDegrees APP never contacts this backend (its address is a build-time
#  constant, so a device is never seen asking a server about a purchase). Only THIS script, on
#  your machine, talks to it. Registration just keeps one source of truth for the address.
#
#  Usage:  bash update-sixdegrees-payments.sh [options]
#    --dry-run              read-only: fetch + verify + show every change, write nothing
#    --deploy               also set Fly secrets and deploy the backend (asks first)
#    --commit               git-commit the backend patch (no push)
#    --yes                  do not ask for confirmation
#    --address ADDR         use this address instead of fetching it (still checksum-validated)
#    --from ajo|scrowit|both  which app(s) define "the address the others use" (default both;
#                             if they differ the script stops and asks you to choose)
#    --mid-xmr N  --deep-xmr N   fixed prices in XMR        (default 0.004 / 0.01)
#    --usd-mid N  --usd-deep N --xmr-usd RATE   price from a USD target at RATE USD per XMR
#    --period-days N        subscription length             (default 30)
#    --stagenet-address A   also set SUBSCRIPTION_XMR_ADDRESS_STAGENET (debug builds)
#    --app-dir D            SixDegrees repo     (default ~/git/sixdegrees-p2p)
#    --backend-dir D        backend repo        (default ~/git/p2p-service-backend)
#    --backend-url URL      live backend        (default $SERVICE_BACKEND_URL or
#                                                https://p2p-service-backend.fly.dev)
#    --fly-app NAME         Fly app name        (default: from fly.toml)
#    --app-id ID            id to register      (default com.techducat.favornet)
#    --pubkey FILE          Ed25519 public key  (default <backend-dir>/keys/service_wallet_public.pem)
#    --skip-app | --skip-services
#  API key (never printed): $SERVICE_API_KEY, else SERVICE_API_KEY in <backend-dir>/local.properties,
#  else a hidden prompt.
# ============================================================================
set -euo pipefail
export LC_ALL=C
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'echo "ERROR: unexpected failure at line $LINENO: $BASH_COMMAND" >&2' ERR

APP_DIR="${APP_DIR:-$HOME/git/sixdegrees-p2p}"
BACKEND_DIR="${BACKEND_DIR:-$HOME/git/p2p-service-backend}"
BACKEND_URL="${SERVICE_BACKEND_URL:-https://p2p-service-backend.fly.dev}"
FLY_APP=""; APP_ID="com.techducat.favornet"; PUBKEY=""
FROM="both"; ADDRESS=""; STAGENET_ADDRESS=""
PRICE_MID="0.004"; PRICE_DEEP="0.01"; PERIOD="30"
USD_MID=""; USD_DEEP=""; XMR_USD=""
DRY=0; DEPLOY=0; COMMIT=0; YES=0; SKIP_APP=0; SKIP_SVC=0
PRICES_FROM_ARGS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;            --deploy) DEPLOY=1 ;;        --commit) COMMIT=1 ;;
    --yes) YES=1 ;;                --skip-app) SKIP_APP=1 ;;    --skip-services) SKIP_SVC=1 ;;
    --address) ADDRESS="${2:?}"; shift ;;           --from) FROM="${2:?}"; shift ;;
    --mid-xmr) PRICE_MID="${2:?}"; PRICES_FROM_ARGS=1; shift ;;
    --deep-xmr) PRICE_DEEP="${2:?}"; PRICES_FROM_ARGS=1; shift ;;
    --usd-mid) USD_MID="${2:?}"; shift ;;           --usd-deep) USD_DEEP="${2:?}"; shift ;;
    --xmr-usd) XMR_USD="${2:?}"; shift ;;           --period-days) PERIOD="${2:?}"; shift ;;
    --stagenet-address) STAGENET_ADDRESS="${2:?}"; shift ;;
    --app-dir) APP_DIR="${2:?}"; shift ;;           --backend-dir) BACKEND_DIR="${2:?}"; shift ;;
    --backend-url) BACKEND_URL="${2:?}"; shift ;;   --fly-app) FLY_APP="${2:?}"; shift ;;
    --app-id) APP_ID="${2:?}"; shift ;;             --pubkey) PUBKEY="${2:?}"; shift ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
step() { echo; echo "${c_grn}==>${c_off} $*"; }
info() { echo "    $*"; }
warn() { echo "${c_ylw}WARN${c_off} $*" >&2; }
die()  { echo "${c_red}ERROR${c_off} $*" >&2; exit 1; }
confirm() { [[ $YES -eq 1 ]] && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
BACKEND_URL="${BACKEND_URL%/}"

# ─── embedded helpers ───────────────────────────────────────────────────────
cat > "$TMP/xmrcheck.py" <<'PY'
import sys
_RC=[0x0000000000000001,0x0000000000008082,0x800000000000808a,0x8000000080008000,0x000000000000808b,0x0000000080000001,0x8000000080008081,0x8000000000008009,0x000000000000008a,0x0000000000000088,0x0000000080008009,0x000000008000000a,0x000000008000808b,0x800000000000008b,0x8000000000008089,0x8000000000008003,0x8000000000008002,0x8000000000000080,0x000000000000800a,0x800000008000000a,0x8000000080008081,0x8000000000008080,0x0000000080000001,0x8000000080008008]
_ROT=[1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44]
_PI=[10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1]
_M=(1<<64)-1
def _rol(x,n): return ((x<<n)|(x>>(64-n)))&_M
def _f(st):
    for rnd in range(24):
        bc=[st[i]^st[i+5]^st[i+10]^st[i+15]^st[i+20] for i in range(5)]
        for i in range(5):
            t=bc[(i+4)%5]^_rol(bc[(i+1)%5],1)
            for j in range(0,25,5): st[j+i]^=t
        t=st[1]
        for i in range(24):
            j=_PI[i]; b=st[j]; st[j]=_rol(t,_ROT[i]); t=b
        for j in range(0,25,5):
            bc=[st[j+i] for i in range(5)]
            for i in range(5): st[j+i]^=(~bc[(i+1)%5])&bc[(i+2)%5]&_M
        st[0]^=_RC[rnd]
def keccak256(data):
    rate=136; p=bytearray(data)+b"\x01"; p+=b"\x00"*((-len(p))%rate); p[-1]|=0x80; st=[0]*25
    for off in range(0,len(p),rate):
        for i in range(rate//8): st[i]^=int.from_bytes(p[off+8*i:off+8*i+8],"little")
        _f(st)
    return b"".join(st[i].to_bytes(8,"little") for i in range(4))
_A="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
_S={0:0,2:1,3:2,5:3,6:4,7:5,9:6,10:7,11:8}
def b58d(s):
    out=bytearray()
    for i in range(0,len(s),11):
        blk=s[i:i+11]
        if len(blk) not in _S: raise ValueError("bad length")
        n=0
        for ch in blk:
            d=_A.find(ch)
            if d<0: raise ValueError("invalid base58 character %r"%ch)
            n=n*58+d
        if n>>(8*_S[len(blk)]): raise ValueError("block overflow")
        out+=n.to_bytes(_S[len(blk)],"big")
    return bytes(out)
NETS={18:("mainnet","standard"),42:("mainnet","subaddress"),19:("mainnet","integrated"),24:("stagenet","standard"),36:("stagenet","subaddress"),25:("stagenet","integrated"),53:("testnet","standard"),63:("testnet","subaddress"),54:("testnet","integrated")}
def check(a):
    raw=b58d(a)
    if len(raw) not in (69,77): raise ValueError("wrong decoded length")
    if keccak256(raw[:-4])[:4]!=raw[-4:]: raise ValueError("checksum mismatch (typo?)")
    if raw[0] not in NETS: raise ValueError("unknown network byte")
    net,kind=NETS[raw[0]]
    if (len(raw)==77)!=(kind=="integrated"): raise ValueError("length/type mismatch")
    return net,kind
try:
    net,kind=check(sys.argv[1].strip())
except ValueError as e:
    print("INVALID: %s"%e); sys.exit(1)
want=sys.argv[2] if len(sys.argv)>2 else None
if want and net!=want: print("INVALID: this is a %s address, a %s one is required"%(net,want)); sys.exit(1)
if kind=="integrated": print("INVALID: integrated addresses embed a payment id; use a standard address or subaddress"); sys.exit(1)
print("%s %s"%(net,kind))
PY

cat > "$TMP/parsecfg.py" <<'PY'
import json,sys,time
try:
    d=json.load(open(sys.argv[1])); appid=sys.argv[2]
    for k in ("appId","walletAddress","timestamp","signature"):
        if k not in d: raise ValueError("response is missing '%s'"%k)
    if d["appId"]!=appid: raise ValueError("response is for a different appId")
    ts=int(d["timestamp"]); age=int(time.time()*1000)-ts
    if age>int(d.get("expiresIn",300000))+60000: raise ValueError("response is stale (%ds old)"%(age//1000))
    if age<-120000: raise ValueError("response timestamp is in the future (clock skew?)")
    print(d["walletAddress"]); print(ts); print(d["signature"])
except Exception as e:
    print("PARSE-ERROR: %s"%e, file=sys.stderr); sys.exit(1)
PY

cat > "$TMP/price.py" <<'PY'
import sys
from decimal import Decimal, ROUND_HALF_UP, getcontext
getcontext().prec=28
usd,rate=Decimal(sys.argv[1]),Decimal(sys.argv[2])
x=usd/rate
# round to 2 significant digits so the amount looks deliberate (0.0038, not 0.0037523...)
exp=x.adjusted(); q=Decimal(1).scaleb(exp-1)
x=x.quantize(q,rounding=ROUND_HALF_UP)
print(format(x.normalize(),"f"))
PY

xmr_validate() { python3 "$TMP/xmrcheck.py" "$1" "${2:-}"; }   # prints "<net> <kind>" or INVALID:..., exit status

# ─── properties-file helpers ────────────────────────────────────────────────
getprop() { # file key -> value (last occurrence, trimmed); empty if absent
  [[ -f "$1" ]] || return 0
  KEY="$2" awk 'BEGIN{k=ENVIRON["KEY"]} $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {sub(/^[^=]*=[[:space:]]*/,""); sub(/[[:space:]\r]+$/,""); v=$0} END{print v}' "$1"
}
setprop() { # file key value -> replaces every uncommented occurrence, appends if none; keeps mode/inode
  local file="$1" key="$2" val="$3"
  KEY="$key" VAL="$val" awk '
    BEGIN{k=ENVIRON["KEY"]; v=ENVIRON["VAL"]; done=0}
    $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print k"="v; done=1; next}
    {print}
    END{if(!done) print k"="v}' "$file" > "$TMP/prop.new"
  cat "$TMP/prop.new" > "$file"
}

# ─── 0. prerequisites ───────────────────────────────────────────────────────
step "Checking prerequisites"
for t in curl openssl python3 awk base64; do command -v "$t" >/dev/null || die "missing tool: $t"; done
openssl pkeyutl -help 2>&1 | grep -q -- '-rawin' || die "OpenSSL too old: need 'pkeyutl -rawin' (OpenSSL >= 3.0) to verify Ed25519 signatures"
case "$BACKEND_URL" in
  https://*) PROTO="=https" ;;
  http://127.0.0.1*|http://localhost*) PROTO="=http,https"; warn "plain HTTP allowed for localhost only" ;;
  *) die "--backend-url must be https:// (got $BACKEND_URL)" ;;
esac
[[ "$FROM" =~ ^(ajo|scrowit|both)$ ]] || die "--from must be ajo, scrowit or both"
[[ "$PERIOD" =~ ^[0-9]+$ && "$PERIOD" -ge 1 && "$PERIOD" -le 366 ]] || die "--period-days must be 1..366"
[[ $SKIP_APP -eq 1 && $SKIP_SVC -eq 1 ]] && die "nothing to do (--skip-app and --skip-services)"
[[ $SKIP_APP -eq 1 ]] || [[ -d "$APP_DIR" ]] || die "SixDegrees repo not found: $APP_DIR (use --app-dir)"
[[ $SKIP_SVC -eq 1 ]] || [[ -f "$BACKEND_DIR/src/routes/appConfig.js" ]] || die "backend repo not found: $BACKEND_DIR (use --backend-dir)"
PUBKEY="${PUBKEY:-$BACKEND_DIR/keys/service_wallet_public.pem}"
APP_LP="$APP_DIR/local.properties"
[[ $DRY -eq 1 ]] && info "DRY RUN: read-only; nothing will be written or deployed"

# ─── 1. API key (only needed to read the address / verify the deployment) ───
API_KEY=""
need_key() {
  [[ -n "$API_KEY" ]] && return 0
  # NOTE: must run in the main shell (not inside $(...)), and logs to stderr so it can never leak
  # into a captured value.
  if [[ -n "${SERVICE_API_KEY:-}" ]]; then API_KEY="$SERVICE_API_KEY"; info "API key: from \$SERVICE_API_KEY" >&2; return 0; fi
  local k; k="$(getprop "$BACKEND_DIR/local.properties" SERVICE_API_KEY)"
  if [[ -n "$k" ]]; then API_KEY="$k"; info "API key: from $BACKEND_DIR/local.properties" >&2; return 0; fi
  [[ -t 0 ]] || die "no API key: set SERVICE_API_KEY or put SERVICE_API_KEY in $BACKEND_DIR/local.properties"
  read -r -s -p "    Backend API key (input hidden): " API_KEY; echo
  [[ -n "$API_KEY" ]] || die "empty API key"
}

# Fetch + verify one app's signed config. Echoes "<address>" on success; non-zero on any failure.
fetch_verified() { # appId
  local appid="$1" out="$TMP/cfg.$RANDOM.json" code
  [[ -n "$API_KEY" ]] || { echo "internal error: API key not loaded" >&2; return 9; }
  code="$(printf 'X-Api-Key: %s\n' "$API_KEY" | curl -sS --proto "$PROTO" --max-time 25 -o "$out" -w '%{http_code}' \
          -H @- -G --data-urlencode "appId=$appid" "$BACKEND_URL/api/v1/config" 2>"$TMP/curl.err" || true)"
  case "$code" in
    200) ;;
    401|403) echo "HTTP $code for $appid ($(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("error",""))' "$out" 2>/dev/null))" >&2; return 2 ;;
    000) echo "cannot reach $BACKEND_URL ($(tr -d '\n' < "$TMP/curl.err" | cut -c1-120))" >&2; return 3 ;;
    *)   echo "HTTP $code for $appid" >&2; return 4 ;;
  esac
  local parsed; parsed="$(python3 "$TMP/parsecfg.py" "$out" "$appid")" || return 5
  local addr ts sig; addr="$(sed -n 1p <<<"$parsed")"; ts="$(sed -n 2p <<<"$parsed")"; sig="$(sed -n 3p <<<"$parsed")"
  [[ -f "$PUBKEY" ]] || { echo "public key not found: $PUBKEY (use --pubkey); refusing to trust an unsigned address" >&2; return 6; }
  printf '%s' "$appid|$addr|$ts" > "$TMP/msg.bin"
  printf '%s' "$sig" | base64 -d > "$TMP/sig.bin" 2>/dev/null || { echo "signature is not valid base64" >&2; return 7; }
  openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin -in "$TMP/msg.bin" -sigfile "$TMP/sig.bin" >/dev/null 2>&1 \
    || { echo "SIGNATURE DOES NOT VERIFY for $appid: do not trust this response" >&2; return 8; }
  echo "$addr"
}

# ─── 2. resolve the payout address ──────────────────────────────────────────
step "Payout address (SUBSCRIPTION_XMR_ADDRESS)"
if [[ -n "$ADDRESS" ]]; then
  info "using --address (not fetched)"
else
  need_key
  srcs=(); case "$FROM" in ajo) srcs=(com.techducat.ajo);; scrowit) srcs=(com.techducat.scrowit);; both) srcs=(com.techducat.ajo com.techducat.scrowit);; esac
  declare -A got=()
  for a in "${srcs[@]}"; do
    info "asking $BACKEND_URL for $a …"
    r="$(fetch_verified "$a")" || die "could not obtain a verified address for $a (see above)"
    got["$a"]="$r"; info "$a → $r  ${c_grn}(signature verified)${c_off}"
  done
  uniq_count="$(printf '%s\n' "${got[@]}" | sort -u | wc -l)"
  if [[ "$uniq_count" -ne 1 ]]; then
    die "Ajo and Scrowit use DIFFERENT addresses (listed above). Re-run with --from ajo or --from scrowit, or pass --address."
  fi
  ADDRESS="${got[${srcs[0]}]}"
fi
v="$(xmr_validate "$ADDRESS" mainnet)" || die "address rejected: $v"
info "valid Monero $v address"
[[ "$ADDRESS" == 4* || "$ADDRESS" == 8* ]] || die "unexpected mainnet prefix"
if [[ -n "$STAGENET_ADDRESS" ]]; then
  v2="$(xmr_validate "$STAGENET_ADDRESS" stagenet)" || die "--stagenet-address rejected: $v2"
  info "stagenet address OK ($v2)"
fi

# ─── 3. prices ──────────────────────────────────────────────────────────────
step "Subscription prices"
if [[ -n "$USD_MID$USD_DEEP$XMR_USD" ]]; then
  [[ -n "$USD_MID" && -n "$USD_DEEP" && -n "$XMR_USD" ]] || die "--usd-mid, --usd-deep and --xmr-usd must be given together"
  [[ $PRICES_FROM_ARGS -eq 0 ]] || die "give either --mid-xmr/--deep-xmr or the --usd-* trio, not both"
  PRICE_MID="$(python3 "$TMP/price.py" "$USD_MID" "$XMR_USD")"; PRICE_DEEP="$(python3 "$TMP/price.py" "$USD_DEEP" "$XMR_USD")"
  info "US\$$USD_MID / US\$$USD_DEEP at US\$$XMR_USD per XMR → $PRICE_MID / $PRICE_DEEP XMR"
fi
python3 - "$PRICE_MID" "$PRICE_DEEP" <<'PY' || die "invalid prices"
import sys
from decimal import Decimal, InvalidOperation
try: m,d=Decimal(sys.argv[1]),Decimal(sys.argv[2])
except InvalidOperation: sys.exit("not a decimal number")
for n,v in (("mid",m),("deep",d)):
    if v<=0: sys.exit(n+" price must be > 0")
    if v>1: sys.exit(n+" price > 1 XMR looks like a typo (about US$300+)")
    if -v.as_tuple().exponent>12: sys.exit(n+" price has more than 12 decimals")
if d<=m: sys.exit("deep price must be higher than mid")
PY
python3 - "$PRICE_MID" "$PRICE_DEEP" "$PERIOD" <<'PY'
import sys
from decimal import Decimal
m,d,p=Decimal(sys.argv[1]),Decimal(sys.argv[2]),sys.argv[3]
print("    Mid  %s XMR / %s days   (≈ US$%.2f at US$350,  US$%.2f at US$533 per XMR)"%(m,p,m*350,m*533))
print("    Deep %s XMR / %s days   (≈ US$%.2f at US$350,  US$%.2f at US$533 per XMR)"%(d,p,d*350,d*533))
if m<Decimal("0.001"): print("WARN mid price is tiny: the ~0.00003 XMR network fee becomes a noticeable share", file=sys.stderr)
PY

# ─── 4. plan ────────────────────────────────────────────────────────────────
step "Plan"
ENVKEY="$(awk -F. '{print toupper($NF)}' <<<"$APP_ID" | tr -c 'A-Z0-9\n' '_')"
if [[ $SKIP_APP -eq 0 ]]; then
  info "SixDegrees  $APP_LP"
  for kv in "SUBSCRIPTION_XMR_ADDRESS=$ADDRESS" "SUBSCRIPTION_PRICE_MID_XMR=$PRICE_MID" "SUBSCRIPTION_PRICE_DEEP_XMR=$PRICE_DEEP" "SUBSCRIPTION_PERIOD_DAYS=$PERIOD"; do
    k="${kv%%=*}"; new="${kv#*=}"; old="$(getprop "$APP_LP" "$k")"
    if [[ -z "$old" ]]; then info "  + $k = $new"; elif [[ "$old" == "$new" ]]; then info "  = $k (unchanged)"; else info "  ~ $k: $old → $new"; fi
  done
  [[ -z "$STAGENET_ADDRESS" ]] || info "  + SUBSCRIPTION_XMR_ADDRESS_STAGENET = $STAGENET_ADDRESS"
fi
if [[ $SKIP_SVC -eq 0 ]]; then
  info "Backend     $BACKEND_DIR"
  info "  register $APP_ID  (env: ${ENVKEY}_WALLET_ADDRESS, ${ENVKEY}_FEE_PERCENTAGE=0) in routes/appConfig.js, .env.example, README.md"
  [[ $DEPLOY -eq 1 ]] && info "  DEPLOY: fly secrets set --stage … ; fly deploy  (PRODUCTION)" || info "  (no --deploy: files patched only; deploy commands printed at the end)"
fi
if [[ $DRY -eq 1 ]]; then echo; echo "Dry run complete. Nothing was written."; exit 0; fi
confirm "Apply these changes?" || { echo "Aborted; nothing changed."; exit 1; }

# ─── 5. SixDegrees variables ────────────────────────────────────────────────
if [[ $SKIP_APP -eq 0 ]]; then
  step "Updating $APP_LP"
  [[ -f "$APP_LP" ]] || { touch "$APP_LP"; chmod 600 "$APP_LP"; info "created (mode 600)"; }
  BK="$APP_LP.bak-$(date +%Y%m%d-%H%M%S)"; cp -p "$APP_LP" "$BK"; info "backup: $BK (contains your other settings; delete when happy)"
  setprop "$APP_LP" SUBSCRIPTION_XMR_ADDRESS "$ADDRESS"
  setprop "$APP_LP" SUBSCRIPTION_PRICE_MID_XMR "$PRICE_MID"
  setprop "$APP_LP" SUBSCRIPTION_PRICE_DEEP_XMR "$PRICE_DEEP"
  setprop "$APP_LP" SUBSCRIPTION_PERIOD_DAYS "$PERIOD"
  [[ -z "$STAGENET_ADDRESS" ]] || setprop "$APP_LP" SUBSCRIPTION_XMR_ADDRESS_STAGENET "$STAGENET_ADDRESS"
  # read back what the build will see
  [[ "$(getprop "$APP_LP" SUBSCRIPTION_XMR_ADDRESS)" == "$ADDRESS" ]] || die "read-back mismatch for SUBSCRIPTION_XMR_ADDRESS"
  info "done; read-back verified"
  if [[ -d "$APP_DIR/.git" ]] && ! git -C "$APP_DIR" check-ignore -q local.properties; then
    warn "local.properties is NOT git-ignored in $APP_DIR; add it to .gitignore"
  fi
fi

# ─── 6. backend service ─────────────────────────────────────────────────────
if [[ $SKIP_SVC -eq 0 ]]; then
  step "Patching backend: register $APP_ID"
  cd "$BACKEND_DIR"
  IS_GIT=0; git rev-parse --is-inside-work-tree >/dev/null 2>&1 && IS_GIT=1
  if [[ $IS_GIT -eq 0 ]]; then
    for f in src/routes/appConfig.js .env.example README.md; do [[ -f "$f" ]] && cp -p "$f" "$f.bak-$(date +%s)"; done
    info "not a git repo: .bak copies made next to each file"
  fi
  APP_ID="$APP_ID" ENVKEY="$ENVKEY" python3 - <<'PY'
import os, re, sys
app, key = os.environ["APP_ID"], os.environ["ENVKEY"]
changed = []

def patch(path, fn):
    if not os.path.exists(path): return
    s = open(path, encoding="utf-8").read(); n = fn(s)
    if n != s: open(path, "w", encoding="utf-8").write(n); changed.append(path)

def routes(s):
    m = re.search(r"const KNOWN_APPS = new Set\(\[(.*?)\]\);", s, re.S)
    if not m: sys.exit("KNOWN_APPS not found in appConfig.js: patch by hand")
    if ("'%s'" % app) not in m.group(1):
        body = m.group(1).rstrip()
        if not body.endswith(","): body += ","
        s = s[:m.start(1)] + body + "\n  '%s',\n" % app + s[m.end(1):]
    doc = " *   %s_WALLET_ADDRESS  %s_FEE_PERCENTAGE" % (key, key)
    if doc not in s:
        s = re.sub(r"( \*   AJO_WALLET_ADDRESS[^\n]*\n)", lambda mm: mm.group(1) + doc + "\n", s, count=1)
    return s

def envex(s):
    if key + "_WALLET_ADDRESS" in s: return s
    block = ("\n# SixDegrees (%s): subscription payments. Fixed XMR prices in the app, so no fee.\n"
             "# NOTE: the app never calls this service; its address is a build-time constant.\n"
             "%s_WALLET_ADDRESS=4...   # Replace with the SixDegrees payout address\n%s_FEE_PERCENTAGE=0\n") % (app, key, key)
    if "AJO_FEE_PERCENTAGE" in s:
        return re.sub(r"(AJO_FEE_PERCENTAGE=[^\n]*\n)", lambda mm: mm.group(1) + block, s, count=1)
    return s + block

def readme(s):
    if "SixDegrees" in s: return s
    s = s.replace("(Scrowit, Ajo)", "(Scrowit, Ajo, SixDegrees)", 1)
    return s.rstrip("\n") + ("\n\n## SixDegrees\n\n`%s` is registered so the payout address has ONE source of truth "
        "(`%s_WALLET_ADDRESS`, set as a Fly secret). The SixDegrees app does **not** call this service: its subscription "
        "address is compiled in at build time so that devices are never seen asking a server about a purchase. "
        "`update-sixdegrees-payments.sh` reads the signed address from here and writes it into the app's `local.properties`.\n") % (app, key)

patch("src/routes/appConfig.js", routes); patch(".env.example", envex); patch("README.md", readme)
print("patched: " + (", ".join(changed) if changed else "nothing (already registered)"))
PY
  if [[ $IS_GIT -eq 1 ]]; then git --no-pager diff --stat -- src/routes/appConfig.js .env.example README.md | sed 's/^/    /'; fi
  if command -v node >/dev/null; then
    node -e "new (require('vm').Script)(require('fs').readFileSync('src/routes/appConfig.js','utf8'))" 2>/dev/null \
      && info "appConfig.js syntax OK" || die "appConfig.js no longer parses: review the patch (git diff)"
  else
    warn "node not installed: could not syntax-check appConfig.js"
  fi

  if [[ $COMMIT -eq 1 && $IS_GIT -eq 1 ]]; then
    git add -- src/routes/appConfig.js .env.example README.md
    if git diff --cached --quiet -- src/routes/appConfig.js .env.example README.md; then info "nothing to commit"
    else git commit -q -m "Register SixDegrees ($APP_ID) in the shared service backend" -- src/routes/appConfig.js .env.example README.md && info "committed (not pushed)"; fi
  fi

  # --- Fly ---
  FLYBIN="$(command -v fly || command -v flyctl || true)"
  if [[ -z "$FLY_APP" && -f fly.toml ]]; then FLY_APP="$(sed -nE "s/^app[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\1/p" fly.toml | head -n1)"; fi
  if [[ $DEPLOY -eq 1 ]]; then
    step "Deploying to Fly (${FLY_APP:-?})"
    [[ -n "$FLYBIN" ]] || die "flyctl not found (https://fly.io/docs/flyctl/install/)"
    [[ -n "$FLY_APP" ]] || die "cannot determine the Fly app name; use --fly-app"
    "$FLYBIN" auth whoami >/dev/null 2>&1 || die "not logged in to Fly: run 'fly auth login'"
    need_key
    confirm "Deploy $FLY_APP to PRODUCTION now? (sets ${ENVKEY}_WALLET_ADDRESS / ${ENVKEY}_FEE_PERCENTAGE, then fly deploy)" || die "deployment declined; local files were patched but nothing was deployed"
    # BEFORE snapshot of the other apps, to prove the deploy did not change their addresses
    declare -A before=()
    for a in com.techducat.ajo com.techducat.scrowit; do before["$a"]="$(fetch_verified "$a" 2>/dev/null || true)"; done
    "$FLYBIN" secrets set --stage -a "$FLY_APP" "${ENVKEY}_WALLET_ADDRESS=$ADDRESS" "${ENVKEY}_FEE_PERCENTAGE=0"
    "$FLYBIN" deploy -a "$FLY_APP"
    step "Verifying the live service"
    ok=0
    for i in 1 2 3 4 5 6 7 8; do
      if r="$(fetch_verified "$APP_ID" 2>"$TMP/v.err")"; then ok=1; break; fi
      info "attempt $i: $(tr -d '\n' < "$TMP/v.err" | cut -c1-100) — retrying in 6s"; sleep 6
    done
    [[ $ok -eq 1 ]] || die "live service did not return a verified config for $APP_ID after deploy"
    [[ "$r" == "$ADDRESS" ]] || die "live service returns a DIFFERENT address for $APP_ID: $r"
    info "$APP_ID → $r  ${c_grn}(signature verified, matches)${c_off}"
    for a in com.techducat.ajo com.techducat.scrowit; do
      now="$(fetch_verified "$a" 2>/dev/null || true)"
      if [[ -n "${before[$a]}" && "$now" != "${before[$a]}" ]]; then die "REGRESSION: $a's address changed across the deploy"; fi
      info "$a unchanged ✓"
    done
  else
    echo; echo "To deploy the backend change (not done; no --deploy):"
    echo "    cd $BACKEND_DIR"
    echo "    fly secrets set --stage -a ${FLY_APP:-<app>} ${ENVKEY}_WALLET_ADDRESS=$ADDRESS ${ENVKEY}_FEE_PERCENTAGE=0"
    echo "    fly deploy -a ${FLY_APP:-<app>}"
  fi
fi

echo
echo "${c_grn}Done.${c_off}"
[[ $SKIP_APP -eq 0 ]] && echo "Next: cd $APP_DIR && ./gradlew assembleRelease   (release builds now have a payout address and prices)"
exit 0
