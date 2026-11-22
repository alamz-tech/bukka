# Menu page fails to load for customers

## How you know
Users report the restaurant menu page is not loading. The symptoms can be:
- **Connection Refused:** No process is listening on the destination, or a firewall is actively rejecting the connection.
- **Connection Timeout:** Packets are being dropped silently (e.g., by a firewall with a DROP policy) or there is a routing issue.
- **DNS Resolution Failure:** The hostname cannot be resolved to an IP address. This is a separate problem and is identified using `dig`.

## Check first
1. **DNS:** `dig google.com` – (Healthy: returns an IP. Broken: times out or returns no answer).  
2. **API Listener:** `ss -tulpn | grep 8080` – (Healthy: listens on `0.0.0.0:8080`. Broken: listens on `127.0.0.1:8080` or not at all).
3. **Firewall (inside container):** `sudo iptables -L INPUT -n -v` – (Healthy: an ACCEPT rule for TCP 8080 exists while policy remains DROP).  
4. **Firewall (host level):** From the **host VM**, run `sudo iptables -L INPUT -n -v` – (Healthy: port 18080 is allowed, but the default DROP policy is intact).  

## Fix
**Inside the container (`bukka-prod-1`):**
1. **Fix API Binding:** `sudo sed -i 's/BUKKA_HOST=127.0.0.1/BUKKA_HOST=0.0.0.0/' /etc/bukka/api.env`
2. **Restart API:** `sudo bukka-api restart`
3. **Fix DNS (temporary):** `echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf`
4. **Open Firewall (inside container):** `sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT`  

**On the host VM:**
5. **Open Host Firewall:** `sudo iptables -A INPUT -p tcp --dport 18080 -j ACCEPT` (Docker often creates its own NAT rules; verify the host firewall is not blocking the mapped port).  

## Why it happens
A recent security policy change broke multiple dependencies simultaneously. It altered the API environment to bind only to localhost (`127.0.0.1`), preventing external traffic. It failed to add an inbound firewall rule for the required application port, and pointed the server's DNS resolver to an unreachable internal IP (`192.0.2.53`).

**Persistence and Limitations:**
- **Firewall:** `iptables-save` writes the current rules to a file, but rules are lost on reboot by default. To survive a full VM/container reboot, you must install and enable `iptables-persistent` (or an equivalent systemd service).  
- **DNS:** Writing `8.8.8.8` directly to `/etc/resolv.conf` is a temporary fix for the lab; in production, use a persistent resolver manager (e.g., `systemd-resolved`).

## Quick Recurrence Check (Under 1 minute)
**From inside the container:**
1. `ss -tulpn | grep 8080` – Expect `0.0.0.0:8080`.
2. `dig github.com` – Expect a valid IP.
3. `curl -s http://localhost:8080/api/restaurants` – Expect JSON data.

**From the host VM:**
4. `curl -s http://localhost:18080/api/restaurants` – Expect JSON data (this confirms external access).
