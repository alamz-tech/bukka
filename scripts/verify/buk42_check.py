"""BUK-42: the production network, read from floci-gcp. Called by buk-42.sh."""
import ipaddress
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gcp  # noqa: E402

check, section = gcp.check, gcp.section
VPC = "bukka-prod-vpc"
# Google's private API ranges: allowed out of the database tier (Private Google Access).
GOOGLE_APIS = [ipaddress.ip_network(n) for n in ("199.36.153.8/30", "199.36.153.4/30")]


def google_only(cidr):
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return False
    return any(net.subnet_of(g) for g in GOOGLE_APIS)


try:
    section("The VPC")
    net = gcp.network(VPC)
    print(f"VPC|{(net or {}).get('id', '')}")
    check(bool(net), f"VPC {VPC} exists", f"gcloud compute networks create {VPC} --subnet-mode=custom")
    check(bool(net) and net.get("autoCreateSubnetworks") is False, f"{VPC} is custom mode (you choose every subnet)",
          "Auto mode creates a subnet in every region with ranges you didn't pick. Delete it and create it with --subnet-mode=custom."
          if net else "Create the VPC first.")

    section("Subnets")
    subs = [s for s in gcp.subnets() if gcp.leaf(s.get("network")) == VPC]
    want = [("bukka-web", "10.0.1.0/24", False), ("bukka-db", "10.0.10.0/24", True)]
    for name, cidr, pga in want:
        s = next((x for x in subs if x.get("name") == name), None)
        label = f"{name}: {cidr} in {gcp.REGION}" + (", Private Google Access on" if pga else "")
        if not s:
            check(False, label, f"No subnet {name} in {VPC}: gcloud compute networks subnets create {name} --network={VPC} "
                                f"--region={gcp.REGION} --range={cidr}" + (" --enable-private-ip-google-access" if pga else ""))
            continue
        got = (s.get("ipCidrRange"), bool(s.get("privateIpGoogleAccess")))
        check(got[0] == cidr and (got[1] or not pga), label,
              f"It's {got[0]}, Private Google Access {'on' if got[1] else 'off'}."
              + (f" gcloud compute networks subnets update {name} --region={gcp.REGION} --enable-private-ip-google-access" if pga and not got[1] else ""))
    extra = [f"{s['name']} ({s.get('ipCidrRange')})" for s in subs if s.get("name") not in {w[0] for w in want}]
    check(not extra, f"{VPC} has only bukka-web and bukka-db", "Also found: " + ", ".join(extra) + ". Delete what you didn't plan.")
    inside = [s for s in subs if not ipaddress.ip_network(s.get("ipCidrRange", "0.0.0.0/0")).subnet_of(ipaddress.ip_network("10.0.0.0/16"))]
    check(not inside, "Every subnet is inside the 10.0.0.0/16 plan",
          "Outside the plan: " + ", ".join(f"{s['name']} {s.get('ipCidrRange')}" for s in inside))

    section("The database tier can't reach the internet, or be reached from it")
    rules = gcp.firewalls(VPC)
    db = lambda r: gcp.applies_to(r, ["bukka-db"], "")
    deny = next((r for r in rules if r.get("name") == "bukka-db-deny-egress"), None)
    deny_ok = bool(deny) and deny.get("direction") == "EGRESS" and (deny.get("targetTags") or []) == ["bukka-db"] \
        and "0.0.0.0/0" in (deny.get("destinationRanges") or []) \
        and any(str(d.get("IPProtocol")).lower() == "all" for d in deny.get("denied") or [])
    check(deny_ok, "bukka-db-deny-egress: EGRESS, deny all to 0.0.0.0/0, for tag bukka-db",
          f"gcloud compute firewall-rules create bukka-db-deny-egress --network={VPC} --direction=EGRESS --action=DENY "
          "--rules=all --destination-ranges=0.0.0.0/0 --target-tags=bukka-db --priority=1000"
          + ("" if not deny else f" (it has: {deny.get('direction')} {deny.get('denied') or deny.get('allowed')} "
                                 f"to {deny.get('destinationRanges')} for {deny.get('targetTags') or 'every VM'})"))
    prio = (deny or {}).get("priority", 1000) if deny_ok else 65535
    leaks = []
    for r in rules:
        if r.get("direction") != "EGRESS" or not r.get("allowed") or not db(r) or r.get("priority", 1000) > prio:
            continue
        dests = [d for d in r.get("destinationRanges") or ["0.0.0.0/0"] if gcp.from_internet(d) and not google_only(d)]
        if dests:
            leaks.append(f"{r['name']} (priority {r.get('priority', 1000)}) allows {', '.join(dests)}")
    check(deny_ok and not leaks, "No rule lets bukka-db out to the internet ahead of the deny",
          ("Remove: " + "; ".join(leaks) + ". A lower priority number wins, so this beats your deny.") if leaks
          else "Create bukka-db-deny-egress first.")
    open_in = []
    for r in rules:
        if r.get("direction", "INGRESS") != "INGRESS" or not r.get("allowed") or not db(r):
            continue
        srcs = [c for c in r.get("sourceRanges") or [] if gcp.from_internet(c)]
        if srcs:
            open_in.append(f"{r['name']} from {', '.join(srcs)}" + ("" if r.get("targetTags") or r.get("targetServiceAccounts")
                                                                    else " (no target tags, so it applies to every VM)"))
    check(not open_in, "Nothing on the internet can reach bukka-db",
          "Open by: " + "; ".join(open_in))
except gcp.Unreachable as e:
    check(False, "Could read your project from floci-gcp", str(e))
