# Menu page fails to load for customers

## How you know
Users report the restaurant menu page is not loading. 
- **Timeout:** Usually indicates a DNS resolution failure (the server cannot find the IP).
- **Connection Refused:** Indicates the firewall is blocking the port, or the application is not listening on the public interface.

## Check first
Run these commands on the server to isolate the fault:
1. `dig google.com` - (Healthy: returns an IP. Broken: times out).
2. `ss -tulpn | grep 8080` - (Healthy: listens on `0.0.0.0:8080`. Broken: listens on `127.0.0.1:8080`).
3. `sudo iptables -L INPUT -n -v` - (Healthy: has an ACCEPT rule for tcp dpt:8080. Broken: policy DROP with no rule).

## Fix
1. **Fix DNS:** `echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf`
2. **Fix API Binding:** `sudo sed -i 's/BUKKA_HOST=127.0.0.1/BUKKA_HOST=0.0.0.0/' /etc/bukka/api.env`
3. **Restart API:** `sudo bukka-api restart`
4. **Open Firewall:** `sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT`
5. **Verify:** `curl -s http://localhost:18080/api/restaurants`

**Quick Recurrence Check (Under 1 minute):**
Run `ss -tulpn | grep 8080` and `dig github.com`. If they return `0.0.0.0:8080` and a valid IP, the core routing is healthy.

## Why it happens
A recent security policy change broke multiple dependencies simultaneously. It altered the API environment to bind only to localhost (`127.0.0.1`), preventing external traffic. It failed to add an inbound firewall rule for TCP port 8080, and pointed the server's DNS resolver to an unreachable internal IP (`192.0.2.53`).

**Persistence Limitations:**
- Running `iptables-save > /etc/iptables/rules.v4` saves the rule, but unless `iptables-persistent` is installed and enabled in systemd, the rule will NOT survive a full container/VM reboot.
- Writing `8.8.8.8` to `/etc/resolv.conf` is a temporary fix for the lab; production environments should use a persistent DNS manager or internal resolver.
