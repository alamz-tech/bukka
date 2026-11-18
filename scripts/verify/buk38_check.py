"""BUK-38: the Google Cloud side, read from floci-gcp. Called by buk-38.sh.
Usage: python3 buk38_check.py <github-username-or-empty>"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gcp  # noqa: E402

KEY_RE = re.compile(r'-----BEGIN (RSA |EC )?PRIVATE KEY-----|"private_key(_id)?"\s*:|AIza[0-9A-Za-z_-]{35}')
SA_ID = "bukka-api-server"
SA = gcp.sa_email(SA_ID)
MEMBER = f"serviceAccount:{SA}"
READ_ROLE = "roles/storage.objectViewer"
# Roles that let someone act as the service account: mint its tokens or keys,
# or attach it to a machine they control.
ACT_AS = {"roles/iam.serviceAccountTokenCreator", "roles/iam.serviceAccountKeyAdmin",
          "roles/iam.serviceAccountUser", "roles/iam.serviceAccountAdmin", "roles/owner", "roles/editor"}

user = (sys.argv[1] if len(sys.argv) > 1 else "").lower()
check, section = gcp.check, gcp.section

try:
    # --- The bucket ---------------------------------------------------------------
    section("The bucket")
    names = [b["name"] for b in gcp.buckets() if b["name"].startswith("bukka-menu-photos-")]
    bucket = f"bukka-menu-photos-{user}" if user and f"bukka-menu-photos-{user}" in names else (names[0] if names else "")
    print(f"BUCKET|{bucket}")
    check(bool(bucket), f"The menu photos bucket exists{f' ({bucket})' if bucket else ''}",
          "gcloud storage buckets create gs://bukka-menu-photos-<your-github-username> --location=us-central1 --uniform-bucket-level-access")

    # --- The service account ----------------------------------------------------------
    section("An identity for the server, not a key")
    sa = gcp.service_account(SA_ID)
    if not check(bool(sa), f"Service account {SA_ID} exists", f"gcloud iam service-accounts create {SA_ID} --display-name=\"Bukka API server\""):
        for name in (f"{SA_ID} has no keys", f"Nobody else can act as {SA_ID}", f"{SA_ID} can read objects in the bucket",
                     f"{SA_ID} has no project-wide roles", f"{SA_ID} has no other access"):
            check(False, name, "Create the service account first.")
    else:
        keys = gcp.user_keys(SA_ID)
        check(not keys, f"{SA_ID} has no keys",
              f"It has {len(keys)} key(s). Delete them: gcloud iam service-accounts keys list --iam-account={SA}, then keys delete <id>. "
              "The server gets credentials from the VM it runs on.")
        sa_pol, proj_pol = gcp.sa_policy(SA_ID), gcp.project_policy()
        risky = []
        for b in sa_pol.get("bindings") or []:
            if b.get("role") in ACT_AS or gcp.PUBLIC & set(b.get("members") or []):
                risky.append(f"{b['role']} for {', '.join(b.get('members') or [])} on the service account")
        for b in proj_pol.get("bindings") or []:
            if b.get("role") in ("roles/iam.serviceAccountTokenCreator", "roles/iam.serviceAccountKeyAdmin") or \
                    gcp.PUBLIC & set(b.get("members") or []):
                risky.append(f"{b['role']} for {', '.join(b.get('members') or [])} on the whole project")
        check(not risky, f"Nobody else can act as {SA_ID} (no token creators, key admins or public members)",
              "Remove: " + "; ".join(risky))

        bpol = gcp.bucket_policy(bucket) if bucket else {}
        has_read = READ_ROLE in gcp.bindings_for(bpol, MEMBER)
        check(has_read, f"{SA_ID} can read objects in {bucket or 'the bucket'} ({READ_ROLE}, on the bucket)",
              f"gcloud storage buckets add-iam-policy-binding gs://{bucket or 'bukka-menu-photos-<username>'} --member={MEMBER} --role={READ_ROLE}")
        proj_roles = gcp.bindings_for(proj_pol, MEMBER)
        check(not proj_roles, f"{SA_ID} has no project-wide roles",
              f"It has {', '.join(proj_roles)} on the whole project, which reaches every bucket. "
              f"gcloud projects remove-iam-policy-binding {gcp.PROJECT} --member={MEMBER} --role=<role>")
        extra = [f"{r} on {bucket}" for r in gcp.bindings_for(bpol, MEMBER) if r != READ_ROLE]
        for b in gcp.buckets():
            if b["name"] != bucket:
                extra += [f"{r} on {b['name']}" for r in gcp.bindings_for(gcp.bucket_policy(b["name"]), MEMBER)]
        check(not extra, f"{SA_ID} has no other access (no writes, no deletes, no other buckets)",
              "Also granted: " + "; ".join(extra) + ". Remove it: least privilege.")
    if bucket:
        public = [f"{b['role']} for {m}" for b in gcp.bucket_policy(bucket).get("bindings") or []
                  for m in b.get("members") or [] if m in gcp.PUBLIC]
        check(not public, f"{bucket} isn't public (no allUsers or allAuthenticatedUsers)",
              "Remove: " + "; ".join(public))
    else:
        check(False, "The bucket isn't public (no allUsers or allAuthenticatedUsers)", "Create the bucket first.")

    # --- The API server --------------------------------------------------------------
    section("The API server")
    vms = gcp.instances("bukka-api-1")
    vm = vms[0] if vms else None
    vm_net = gcp.leaf(((vm or {}).get("networkInterfaces") or [{}])[0].get("network")) if vm else "default"
    tags = ((vm or {}).get("tags") or {}).get("items") or []
    rules = [r for r in gcp.firewalls(vm_net) if r.get("direction", "INGRESS") == "INGRESS" and r.get("allowed")]
    web = next((r for r in rules if r.get("name") == "bukka-allow-web"), None)
    web_ok = bool(web) and "0.0.0.0/0" in (web.get("sourceRanges") or []) and gcp.opens(web, 80) and gcp.opens(web, 443) \
        and (web.get("targetTags") or []) == ["bukka-web"]
    check(web_ok, f"Firewall rule bukka-allow-web: TCP 80 and 443 from 0.0.0.0/0 to tag bukka-web (network {vm_net})",
          f"gcloud compute firewall-rules create bukka-allow-web --network={vm_net} --direction=INGRESS "
          "--allow=tcp:80,tcp:443 --source-ranges=0.0.0.0/0 --target-tags=bukka-web"
          + ("" if not web else f" (it has: {web.get('allowed')} from {web.get('sourceRanges')} to {web.get('targetTags') or 'every VM'})"))
    mine = [r for r in rules if gcp.applies_to(r, tags or ["bukka-web"], SA)]
    ssh_bad = [f"{r['name']} ({', '.join(r.get('sourceRanges') or r.get('sourceTags') or r.get('sourceServiceAccounts') or ['?'])})"
               for r in mine if gcp.opens(r, 22) and not (r.get("sourceRanges") and all(gcp.single_host(c) for c in r["sourceRanges"])
                                                          and not r.get("sourceTags") and not r.get("sourceServiceAccounts"))]
    check(not ssh_bad, "SSH (22) is closed, or open only to one /32",
          f"Open by: {'; '.join(ssh_bad)}. Delete the rule, or allow only <your-ip>/32.")
    other = []
    for r in mine:
        if r is web:
            continue
        ports, protos = gcp.tcp_ports(r)
        if ports is not None and not protos and ports == {22}:
            continue  # SSH-only: judged by the check above
        what = "everything" if ports is None else ", ".join([f"tcp:{p}" for p in sorted(ports - {22})][:5] + protos)
        other.append(f"{r['name']} opens {what}")
    check(not other, "No other inbound rules reach bukka-api-1",
          "Also open: " + "; ".join(other)[:250] + ". A rule with no target tags applies to every VM in the network.")

    if not check(len(vms) == 1, "One VM called bukka-api-1",
                 "Found none. gcloud compute instances create bukka-api-1 ... (see the ticket)" if not vms
                 else f"Found {len(vms)}. Delete the extras."):
        for n in ("is an e2-micro", "has the network tag bukka-web", f"runs as {SA_ID}", "No keys in bukka-api-1's metadata"):
            check(False, f"bukka-api-1 {n}" if not n.startswith("No") else n, "Create bukka-api-1 first.")
    else:
        mt = gcp.leaf(vm.get("machineType"))
        check(mt == "e2-micro", "bukka-api-1 is an e2-micro", f"It's a {mt}.")
        check("bukka-web" in tags, "bukka-api-1 has the network tag bukka-web",
              f"Its tags: {tags or 'none'}. gcloud compute instances add-tags bukka-api-1 --tags=bukka-web")
        sas = vm.get("serviceAccounts") or []
        runs_as = [s.get("email") for s in sas]
        scopes = [sc for s in sas for sc in s.get("scopes") or []]
        check(runs_as == [SA] and "https://www.googleapis.com/auth/cloud-platform" in scopes,
              f"bukka-api-1 runs as {SA_ID} (scope cloud-platform)",
              f"It runs as {runs_as or 'nothing'}. Create it with --service-account={SA} --scopes=cloud-platform. "
              "Without it, a VM gets the Compute default service account, which on real projects can edit almost everything.")
        meta = " ".join(str(i.get("value", "")) for i in (vm.get("metadata") or {}).get("items") or [])
        check(not KEY_RE.search(meta), "No keys in bukka-api-1's metadata",
              "Its metadata (e.g. startup-script) has a private key or API key in it. The service account is how the server gets access.")

    # --- Budget ------------------------------------------------------------------------
    section("No surprise bills")
    topic_name = f"projects/{gcp.PROJECT}/topics/bukka-billing-alerts"
    has_topic = bool(gcp.topic("bukka-billing-alerts"))
    check(has_topic, "Pub/Sub topic bukka-billing-alerts exists", "gcloud pubsub topics create bukka-billing-alerts")
    check(has_topic and bool(gcp.topic_subscriptions("bukka-billing-alerts")), "Someone is subscribed to bukka-billing-alerts",
          "gcloud pubsub subscriptions create bukka-billing-alerts-oncall --topic=bukka-billing-alerts")
    all_budgets = gcp.budgets()
    if all_budgets is None:
        b = None
        check(False, "Budget bukka-spend-above-zero exists",
              "This floci-gcp has no Budget API. Use the version in the ticket's Notes.")
    else:
        found = [x for x in all_budgets if x.get("displayName") == "bukka-spend-above-zero"]
        b = found[0] if found else None
        check(len(found) == 1, f"Budget bukka-spend-above-zero exists on billing account {gcp.BILLING}",
              "None found: create it with the curl command in the ticket's Notes." if not found
              else f"Found {len(found)}. Delete the extras.")
    if b:
        amt = (b.get("amount") or {}).get("specifiedAmount") or {}
        cap = gcp.money(amt)
        lows = [t.get("thresholdPercent", 1) for t in b.get("thresholdRules") or []]
        first = cap * min(lows) if lows else None
        check(amt.get("currencyCode", "USD") == "USD" and first is not None and 0 < first <= 0.01,
              "The budget alerts at the first cent spent (1 USD, threshold 1%)",
              f"It's {cap:g} {amt.get('currencyCode', '?')} with thresholds {lows or 'none'}: the first alert comes at "
              f"{'never' if first is None else f'${first:.2f}'}. Use amount 1 USD and a threshold of 0.01.")
        rule = b.get("notificationsRule") or {}
        check(rule.get("pubsubTopic") == topic_name, "The budget notifies bukka-billing-alerts",
              f"It notifies {rule.get('pubsubTopic') or 'nothing'}. Set notificationsRule.pubsubTopic to {topic_name} (schemaVersion 1.0).")
    else:
        check(False, "The budget alerts at the first cent spent (1 USD, threshold 1%)", "Create the budget first.")
        check(False, "The budget notifies bukka-billing-alerts", "Create the budget first.")
except gcp.Unreachable as e:
    check(False, "Could read your project from floci-gcp", str(e))
