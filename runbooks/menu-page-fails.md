# Menu page fails to load for customers

## How you know
Customers say the app "keeps loading" and the restaurant list never appears. From outside the server this hangs and then fails:

`curl -v --max-time 5 http://localhost:18080/api/restaurants`

The connection is established and the request is sent, but no reply comes back: `Operation timed out after 5002 milliseconds with 0 bytes received`.

## Check first
Run these in order. The first one that looks wrong tells you which layer is broken. Checks 2 to 5 run inside the server: `docker exec -it -u oncall bukka-prod-1 bash`.

Quick check (under a minute): run check 1. If it returns the restaurant list, the problem is not happening. If it times out, run checks 3, 4 and 5.

1. From outside: `curl --max-time 5 http://localhost:18080/api/restaurants`
   - Healthy: a JSON list of restaurants.
   - Broken: `Operation timed out ... 0 bytes received`.
   - Tells you: whether customers can reach the API at all.

2. Inside: `curl -s http://127.0.0.1:8080/api/restaurants`
   - Healthy: the same JSON list.
   - Broken: an error or nothing. During this incident it worked, which proved the API itself was healthy and the fault was around it.

3. Inside: `ss -tlnp`
   - Healthy: `0.0.0.0:8080` owned by python.
   - Broken: `127.0.0.1:8080` (accepts connections only from inside the server), or no line for 8080 (API not running).

4. Inside: `sudo iptables -S`
   - Healthy: `-P INPUT DROP` plus a rule `-A INPUT -p tcp -m tcp --dport 8080 -j ACCEPT`.
   - Broken: `-P INPUT DROP` with no rule for port 8080, so customer traffic is dropped silently.

5. Inside: `timeout 5 getent hosts example.com; echo "exit code: $?"`
   - Healthy: an address and `exit code: 0`.
   - Broken: nothing printed and `exit code: 124` (the lookup timed out). Also look at `cat /etc/resolv.conf`: a healthy one points at a resolver that answers (here `192.168.43.1`, copied by Docker from the host).

## Fix
Fix every cause the checks show, because fixing one can reveal the next. Keep the firewall on with default-deny. Never switch it off.

### 1. The API listens only on 127.0.0.1
1. Back up the file: `sudo cp /etc/bukka/api.env /etc/bukka/api.env.bak`
2. Set the host: `sudo sed -i 's/^BUKKA_HOST=.*/BUKKA_HOST=0.0.0.0/' /etc/bukka/api.env`
3. Restart: `bukka-api restart`, then `ss -tlnp` should show `0.0.0.0:8080`.

Change it in `/etc/bukka/api.env`. `bukka-api start` reads that file every time, so a fix made anywhere else is lost on restart.

### 2. The firewall has no rule for port 8080
1. `sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT`
2. `sudo iptables -S` should show the new rule, and `-P INPUT DROP` must still be there.

### 3. The DNS resolver is unreachable
1. Keep the broken file: `sudo cp /etc/resolv.conf /etc/resolv.conf.broken`
2. Restore the working one: `sudo cp /etc/resolv.conf.docker /etc/resolv.conf`
3. `timeout 5 getent hosts example.com` should print an address, and `sudo apt-get update` should download package lists.

### Confirm
From outside, check 1 returns the restaurants. Run `bukka-api restart` once more and repeat checks 1, 3 and 4. They must still be healthy.

## Why it happens
A security change on bukka-prod-1 left three things wrong at once. The API was told to listen only on `127.0.0.1`, so it ignored anything arriving from outside. The firewall was default-deny but had no rule allowing port 8080, so customer traffic was dropped. The DNS resolver in `/etc/resolv.conf` was changed to `192.0.2.53`, an address nothing answers on, so every name lookup (including `apt`) hung, even though the network itself worked (a connection to 1.1.1.1 by number succeeded).

Connection refused versus timeout: "refused" means the machine answered at once that nothing is listening on that port. A timeout means no answer came back at all. In this incident we saw a timeout from outside, caused by the firewall dropping the packets silently. We did not see "refused", because the firewall dropped the traffic before it reached the API. A stopped API or one bound to the wrong address is what would normally produce "refused", but that is reasoning, not something observed here.

The firewall rule was added to the running firewall. This ticket did not find where the rules are defined, so if the firewall is reloaded or the server rebuilt, run check 4 again.
