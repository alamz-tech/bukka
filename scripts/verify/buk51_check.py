"""BUK-51: everything BUK-38, BUK-42 and BUK-45 checked on the Google Cloud
side still holds, now that Terraform builds it. Runs those checks and adds the
ones that only make sense once it's one stack. Called by buk-51.sh.
Usage: python3 buk51_check.py <github-username-or-empty>"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gcp  # noqa: E402

user = sys.argv[1] if len(sys.argv) > 1 else ""
# Checks that belong to the ticket they came from, not to the Terraform stack.
SKIP = ("At least three photos under dishes/",   # Terraform manages the bucket, not the photos
        "bukka-prod-vpc exists (BUK-42)",          # BUK-42's own checks cover it
        "The menu photos bucket exists")           # BUK-38's own check covers it
seen = set()


def relay(script, title):
    gcp.section(title)
    out = subprocess.run([sys.executable, os.path.join(HERE, script), user], capture_output=True, text=True)
    lines = out.stdout.splitlines() or [f"FAIL|{script} ran|{out.stderr.strip()[-200:]}"]
    for line in lines:
        kind, _, rest = line.partition("|")
        name = rest.split("|")[0]
        if kind == "SECTION":
            continue
        if kind in ("PASS", "FAIL") and (name in seen or (script == "buk45_check.py" and name.startswith(SKIP))):
            continue
        seen.add(name)
        print(line)


relay("buk42_check.py", "The network (BUK-42)")
relay("buk38_check.py", "The API server and the budget (BUK-38)")
relay("buk45_check.py", "The database firewall and the photos bucket (BUK-45)")

gcp.section("One stack")
try:
    vms = gcp.instances("bukka-api-1")
    nic = ((vms[0].get("networkInterfaces") or [{}])[0]) if len(vms) == 1 else {}
    gcp.check(gcp.leaf(nic.get("network")) == "bukka-prod-vpc" and gcp.leaf(nic.get("subnetwork")) == "bukka-web",
              "bukka-api-1 runs in the bukka-web subnet of bukka-prod-vpc",
              f"It's in {gcp.leaf(nic.get('subnetwork')) or '?'} on {gcp.leaf(nic.get('network')) or '?'}. "
              "Pass the network module's web subnet into the compute module.")
    stray = [n["name"] for n in gcp.items(f"{gcp.COMPUTE}/global/networks") if n.get("name") != "bukka-prod-vpc"]
    gcp.check(not stray, "bukka-prod-vpc is the only network (the default network from BUK-38 is gone)",
              "Also found: " + ", ".join(stray) + ". Start from a fresh floci-gcp and terraform apply.")
except gcp.Unreachable as e:
    gcp.check(False, "Could read your project from floci-gcp", str(e))
