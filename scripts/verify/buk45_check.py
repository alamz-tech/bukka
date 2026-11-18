"""BUK-45: the Google Cloud side, read from floci-gcp. Called by buk-45.sh.
Usage: python3 buk45_check.py <github-username-or-empty>"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gcp  # noqa: E402

check = gcp.check
VPC = "bukka-prod-vpc"
API_SA = gcp.sa_email("bukka-api-server")
DB_SA = gcp.sa_email("bukka-orders-db")
user = (sys.argv[1] if len(sys.argv) > 1 else "").lower()

try:
    check(bool(gcp.network(VPC)), f"{VPC} exists (BUK-42)", "Rebuild BUK-42 with infra/cli/buk-42.sh.")
    check(bool(gcp.service_account("bukka-api-server")) and bool(gcp.service_account("bukka-orders-db")),
          "Service accounts bukka-api-server (BUK-38) and bukka-orders-db exist",
          "Rebuild BUK-38, then: gcloud iam service-accounts create bukka-orders-db --display-name=\"Bukka orders database\"")
    rules = [r for r in gcp.firewalls(VPC) if r.get("direction", "INGRESS") == "INGRESS" and r.get("allowed")]
    rule = next((r for r in rules if r.get("name") == "bukka-db-allow-api"), None)
    ports, protos = gcp.tcp_ports(rule) if rule else (None, [])
    ok = bool(rule) and ports == {5432} and not protos \
        and (rule.get("sourceServiceAccounts") or []) == [API_SA] \
        and not rule.get("sourceRanges") and not rule.get("sourceTags") \
        and (rule.get("targetServiceAccounts") or []) == [DB_SA] and not rule.get("targetTags")
    check(ok, "bukka-db-allow-api: TCP 5432 only, from the bukka-api-server service account to bukka-orders-db",
          f"gcloud compute firewall-rules create bukka-db-allow-api --network={VPC} --direction=INGRESS --allow=tcp:5432 "
          f"--source-service-accounts={API_SA} --target-service-accounts={DB_SA}"
          + ("" if not rule else f" (it has: {rule.get('allowed')} from ranges {rule.get('sourceRanges')}, "
                                 f"tags {rule.get('sourceTags')}, accounts {rule.get('sourceServiceAccounts')} "
                                 f"to {rule.get('targetServiceAccounts') or rule.get('targetTags') or 'every VM'})"))
    others = [r["name"] for r in rules if r is not rule and gcp.applies_to(r, ["bukka-db"], DB_SA)]
    check(not others, "No other inbound rule reaches the database",
          "Also reaching it: " + ", ".join(others) + ". A rule with no targets applies to every VM.")

    names = [b["name"] for b in gcp.buckets() if b["name"].startswith("bukka-menu-photos-")]
    bucket = f"bukka-menu-photos-{user}" if user and f"bukka-menu-photos-{user}" in names else (names[0] if names else "")
    print(f"BUCKET|{bucket}")
    if not check(bool(bucket), f"The menu photos bucket exists{f' ({bucket})' if bucket else ''}", "Rebuild BUK-38 with infra/cli/buk-38.sh."):
        for n in ("Uniform bucket-level access is on", "Public access prevention is enforced", "Object versioning is on",
                  "At least three photos under dishes/"):
            check(False, n, "No menu photos bucket.")
    else:
        b = gcp.bucket(bucket) or {}
        iam = b.get("iamConfiguration") or {}
        check(bool((iam.get("uniformBucketLevelAccess") or {}).get("enabled")), "Uniform bucket-level access is on",
              f"gcloud storage buckets update gs://{bucket} --uniform-bucket-level-access")
        check(iam.get("publicAccessPrevention") == "enforced", "Public access prevention is enforced",
              f"Got: {iam.get('publicAccessPrevention') or 'not set'}. gcloud storage buckets update gs://{bucket} --public-access-prevention")
        check(bool((b.get("versioning") or {}).get("enabled")), "Object versioning is on",
              f"gcloud storage buckets update gs://{bucket} --versioning")
        n = len(gcp.objects(bucket, "dishes/"))
        check(n >= 3, f"At least three photos under dishes/ ({n})",
              f"Found {n}. gcloud storage cp jollof-rice.jpg gs://{bucket}/dishes/mama-put-yaba/jollof-rice.jpg")
except gcp.Unreachable as e:
    check(False, "Could read your project from floci-gcp", str(e))
