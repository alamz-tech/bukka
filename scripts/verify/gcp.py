"""Read-only helpers the BUK-38/42/45/51 verify scripts use to look at what
you built on floci-gcp. They only ever GET: nothing here changes your cloud.

Each check prints one line, read by the bash verify script:
  PASS|<what was checked>
  FAIL|<what was checked>|<how to fix it>
  SECTION|<heading>
"""
import ipaddress
import json
import os
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("FLOCI_GCP", "http://localhost:4588").rstrip("/")
PROJECT = os.environ.get("CLOUDSDK_CORE_PROJECT") or "bukka-prod"
BILLING = os.environ.get("BUKKA_BILLING_ACCOUNT") or "000000-000000-000000"
REGION = "us-central1"
COMPUTE = f"/compute/v1/projects/{PROJECT}"


class Unreachable(Exception):
    pass


def get(path, params=None):
    """GET a floci-gcp REST path. Returns the JSON, or None for 404."""
    url = BASE + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer floci-fake-token"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read().decode("utf-8", "replace")
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise Unreachable(f"{e.code} from {path}")
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Unreachable(str(e))


def post(path, body=None):
    """POST for read-only methods that use it (getIamPolicy)."""
    req = urllib.request.Request(BASE + path, data=json.dumps(body or {}).encode(), method="POST",
                                 headers={"Authorization": "Bearer floci-fake-token", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise Unreachable(f"{e.code} from {path}")
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Unreachable(str(e))


def items(path, key="items", params=None):
    out, token = [], None
    while True:
        p = dict(params or {})
        if token:
            p["pageToken"] = token
        page = get(path, p) or {}
        out += page.get(key) or []
        token = page.get("nextPageToken")
        if not token:
            return out


def answering():
    try:
        get(f"{COMPUTE}/global/networks")
        return True
    except Unreachable:
        return False


# --- Compute ------------------------------------------------------------------
def leaf(link):
    return (link or "").rstrip("/").split("/")[-1]


def network(name):
    return get(f"{COMPUTE}/global/networks/{name}")


def subnets():
    return items(f"{COMPUTE}/regions/{REGION}/subnetworks")


def firewalls(network_name=None):
    rules = items(f"{COMPUTE}/global/firewalls")
    if network_name:
        rules = [r for r in rules if leaf(r.get("network")) == network_name]
    return [r for r in rules if not r.get("disabled")]


def instances(name=None):
    zones = [z["name"] for z in items(f"{COMPUTE}/zones") if leaf(z.get("region")) == REGION] or \
            [f"{REGION}-{x}" for x in "abcf"]
    out = []
    for z in zones:
        out += items(f"{COMPUTE}/zones/{z}/instances")
    return [i for i in out if name is None or i.get("name") == name]


def applies_to(rule, tags, sa_email):
    """Does a firewall rule apply to a VM with these network tags and service account?
    A rule with no targets applies to every VM in the network."""
    tt, ts = rule.get("targetTags") or [], rule.get("targetServiceAccounts") or []
    if not tt and not ts:
        return True
    return bool(set(tt) & set(tags or [])) or (sa_email in ts)


def _ports(entry):
    proto = str(entry.get("IPProtocol", "")).lower()
    if proto in ("all",):
        return None  # everything
    if proto not in ("tcp", "6"):
        return set()
    ports = entry.get("ports") or []
    if not ports:
        return None
    got = set()
    for p in ports:
        lo, _, hi = str(p).partition("-")
        got |= set(range(int(lo), int(hi or lo) + 1))
    return got


def opens(rule, port):
    """True if an ALLOW rule opens this TCP port (protocol 'all' or no port list counts)."""
    for a in rule.get("allowed") or []:
        ps = _ports(a)
        if ps is None or port in ps:
            return True
    return False


def tcp_ports(rule):
    """The TCP ports an ALLOW rule opens, or None for 'everything', and any non-TCP protocols."""
    ports, other = set(), []
    for a in rule.get("allowed") or []:
        ps = _ports(a)
        if ps is None:
            return None, []
        if not ps and str(a.get("IPProtocol")).lower() not in ("tcp", "6"):
            other.append(str(a.get("IPProtocol")))
        ports |= ps
    return ports, other


def from_internet(cidr):
    """A source range that isn't a private (RFC 1918) range."""
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return True
    return not net.is_private or net.prefixlen == 0


def single_host(cidr):
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return False
    return net.version == 4 and net.prefixlen == 32 and not net.is_unspecified


# --- IAM -------------------------------------------------------------------------
def sa_email(account_id):
    return f"{account_id}@{PROJECT}.iam.gserviceaccount.com"


def service_account(account_id):
    return get(f"/v1/projects/{PROJECT}/serviceAccounts/{sa_email(account_id)}")


def user_keys(account_id):
    keys = (get(f"/v1/projects/{PROJECT}/serviceAccounts/{sa_email(account_id)}/keys") or {}).get("keys") or []
    return [k for k in keys if k.get("keyType", "USER_MANAGED") == "USER_MANAGED"]


def sa_policy(account_id):
    return post(f"/v1/projects/{PROJECT}/serviceAccounts/{sa_email(account_id)}:getIamPolicy") or {}


def project_policy():
    return post(f"/v1/projects/{PROJECT}:getIamPolicy") or {}


def bindings_for(policy, member):
    return sorted({b["role"] for b in policy.get("bindings") or [] if member in (b.get("members") or [])})


# --- Cloud Storage -----------------------------------------------------------------
def buckets():
    return items("/storage/v1/b", params={"project": PROJECT})


def bucket(name):
    return get(f"/storage/v1/b/{urllib.parse.quote(name, safe='')}")


def bucket_policy(name):
    return get(f"/storage/v1/b/{urllib.parse.quote(name, safe='')}/iam") or {}


def objects(name, prefix=""):
    return items(f"/storage/v1/b/{urllib.parse.quote(name, safe='')}/o", params={"prefix": prefix} if prefix else None)


PUBLIC = {"allUsers", "allAuthenticatedUsers"}


# --- Pub/Sub and budgets --------------------------------------------------------
def topic(name):
    return get(f"/v1/projects/{PROJECT}/topics/{name}")


def topic_subscriptions(name):
    full = f"projects/{PROJECT}/topics/{name}"
    subs = (get(f"/v1/projects/{PROJECT}/subscriptions") or {}).get("subscriptions") or []
    return [s for s in subs if s.get("topic") == full]


def budgets():
    """None when this floci-gcp has no Budget API (older than 0.14)."""
    page = get(f"/v1/billingAccounts/{BILLING}/budgets")
    if page is None:
        return None
    return page.get("budgets") or []


def money(m):
    m = m or {}
    return int(m.get("units") or 0) + int(m.get("nanos") or 0) / 1e9


# --- Output ---------------------------------------------------------------------------
def section(title):
    print(f"SECTION|{title}")


def check(ok, name, hint=""):
    hint = " ".join(str(hint).split())[:300]
    print(f"PASS|{name}" if ok else f"FAIL|{name}|{hint}")
    return ok
