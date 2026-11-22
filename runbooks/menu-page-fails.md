# Menu page fails to load for customers

## How you know
Users report the restaurant menu page is not loading. The API endpoint `http://localhost:18080/api/restaurants` returns a connection refused or timeout error.

## Check first
1. `ss -tulpn | grep 8080` - Check if the API is listening on `0.0.0.0:8080` (not `127.0.0.1:8080`).
2. `sudo iptables -L -n -v` - Check if there is an `ACCEPT` rule for `tcp dpt:8080` while the policy remains `DROP`.
3. `cat /etc/bukka/api.env` - Check that `BUKKA_HOST` is set to `0.0.0.0`.
4. `cat /etc/resolv.conf` and `dig google.com` - Check if DNS is resolving (should return an IP, not time out).

## Fix
1. Update the API to listen on all interfaces: `sudo sed -i 's/BUKKA_HOST=127.0.0.1/BUKKA_HOST=0.0.0.0/' /etc/bukka/api.env`
2. Restart the API: `sudo bukka-api restart`
3. Fix DNS resolution (replace with a valid resolver if the internal one is down): `echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf`
4. Open the firewall for the application port while maintaining default-deny: `sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT`
5. Save the firewall rules to persist across reboots: `sudo mkdir -p /etc/iptables && sudo sh -c "iptables-save > /etc/iptables/rules.v4"`

## Why it happens
A recent security policy change broke multiple dependencies simultaneously. It altered the API environment to bind only to localhost (`127.0.0.1`), preventing external traffic from reaching it. Additionally, the policy failed to add an inbound firewall rule for TCP port 8080, and pointed the server's DNS resolver to an unreachable internal IP (`192.0.2.53`), which broke outbound connectivity.
