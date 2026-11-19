cat > runbooks/menu-page-fails.md << 'EOF'
# Menu page fails to load (restaurant list never appears)

## How you know
- Customers report the app "keeps loading", the restaurant list never shows, or they get an error page.
- `curl http://localhost:18080/api/restaurants` from outside the server fails (reset, refused, or timeout) instead of returning the restaurant JSON.
- Apt updates and outbound calls from the server also fail, and DNS lookups fail or are very slow.

## Check first
Work from the outside in, one layer at a time. Run step 1 from outside the server, and the rest on the server (`docker exec -it -u oncall bukka-prod-1 bash`).

1. `curl -v --max-time 10 http://localhost:18080/api/restaurants` (from outside). Healthy: `200 OK` and JSON. Note how it fails:
   - "Connection refused" or "reset by peer" means the packet reached the machine but nothing accepted it. Suspect the service: not running, or listening on the wrong address.
   - A timeout (no response at all) means packets are being silently dropped. Suspect the firewall.
2. `bukka-api status` and `ss -tlnp`. Healthy: running, with the API listening on `0.0.0.0:8080`. In this incident it listened on `127.0.0.1:8080`, so only the server itself could reach it.
3. `curl -v http://127.0.0.1:8080/api/restaurants` (on the server). If this returns `200`, the app is healthy and the fault is in how it is exposed.
4. `grep BUKKA_HOST /etc/bukka/api.env`. Healthy: `BUKKA_HOST=0.0.0.0`. This file is read by `bukka-api start`, so it is where the bind address lives.
5. `sudo iptables -L INPUT -n -v --line-numbers`. Healthy: `policy DROP` plus ACCEPT rules for established traffic, `tcp dpt:8080`, loopback, ssh and icmp. In this incident there was no rule for 8080 and the DROP counter was climbing.
6. `cat /etc/resolv.conf`, then `dig example.com` and `getent hosts example.com`. Healthy: the nameserver answers quickly. In this incident `resolv.conf` pointed at `192.0.2.53`, which times out (that range is reserved for documentation and is not a real server).
7. `bukka-api logs 20`. Check `response_time_ms` on each request. Seconds instead of milliseconds pointed at the DNS problem here.

Quick check (under a minute) for whether this has happened again. On the server, run:

    bukka-api status
    ss -tlnp | grep 8080
    sudo iptables -L INPUT -n | head -1
    sudo iptables -L INPUT -n | grep 8080
    grep BUKKA_HOST /etc/bukka/api.env
    getent hosts example.com

Healthy output: `bukka-api is running`; a listener on `0.0.0.0:8080`; `policy DROP`; an `ACCEPT ... tcp dpt:8080` line; `BUKKA_HOST=0.0.0.0`; and `getent` returning an address. Then from outside, `curl http://localhost:18080/api/restaurants` should return the restaurants. Any missing item points at the fault to fix.

## Fix
Fix one cause at a time and re-test from outside after each, because fixing one reveals the next.

1. Bind address: `sudo sed -i 's/^BUKKA_HOST=.*/BUKKA_HOST=0.0.0.0/' /etc/bukka/api.env`, then `bukka-api restart`, wait a few seconds, and confirm with `ss -tlnp` (see the notes below).
2. Firewall: keep default-deny and open only what customers need. Add ACCEPT rules before setting the DROP policy, and only add rules that are missing, to avoid duplicates:

        sudo iptables -A INPUT -i lo -j ACCEPT
        sudo iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        sudo iptables -A INPUT -p icmp -j ACCEPT
        sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
        sudo iptables -P INPUT DROP

   Do not disable or flush the firewall. Do not skip the conntrack rule (no space after the comma in `RELATED,ESTABLISHED`), or replies to outbound requests such as DNS and apt are dropped.
3. DNS: first prove the replacement resolver works with `dig @192.168.65.7 example.com`, then `echo "nameserver 192.168.65.7" | sudo tee /etc/resolv.conf`. Verify with `getent hosts example.com`, `sudo apt-get update` and `curl -sI https://example.com`.
4. Final check from outside: `curl http://localhost:18080/api/restaurants` returns the restaurants.

Notes:
- `bukka-api restart` can print "already running" without bringing the API back, because the start step runs before the old process has fully exited. Always confirm with `bukka-api status` and `ss -tlnp`, and run `bukka-api start` if it is down. The service can also take a few seconds to start listening.
- The `api.env` change survives `bukka-api restart`. The firewall rules and `resolv.conf` edits are live changes only: in the lab the firewall was reset when the container restarted. On a real server they need to be made persistent (a saved iptables/nftables config and the resolver configuration).

## Why it happens
A security-policy change caused three separate faults at once: the API was set to listen only on `127.0.0.1`, the firewall dropped all inbound traffic except ssh with no rule for port 8080, and `resolv.conf` pointed at an unreachable resolver. The first made connections from outside fail immediately (refused or reset), the second made them hang until they timed out, and the third broke apt and outbound calls and made API responses slow (observed falling from about 4 seconds to a few milliseconds as DNS was repaired; the link to DNS was not tested separately). The faults hide each other, so one fix is not enough. As a side note, the on-call account has unrestricted passwordless sudo, which is broader than it needs to be.
EOF
