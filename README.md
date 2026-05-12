# Redirector

An interactive setup script that turns a Linux box into a reverse proxy using Apache2 or Nginx. The idea is simple: you put a domain or an IP in front, forward traffic to a real backend, and you decide whether any request goes through or only the ones that look legitimate (allowed path prefixes, plus an optional User-Agent filter). Anything that does not match gets a 404, as if nothing was ever there.

It is built for operator-style scenarios: you want to expose a backend through an intermediate host, but you do not want scanners and random visitors to see more than they should. Both HTTP and HTTPS are configured out of the box, with a locally generated self-signed certificate. If you need a real cert, you swap the files in `/etc/ssl/redirector/` after the run.

## What it actually does

* Asks which web server you want (`nginx` or `apache2`) and installs whatever is missing.
* Asks for the backend URL (for example `http://10.0.0.20:8080` or `https://api.internal.local`).
* Asks for the server name and which ports to listen on (defaults are 80 and 443).
* Lets you pick the operating mode:
  * `catchall` proxies every request to the backend.
  * `targeted` only proxies requests matching the allowed path prefixes (for example `/api,/health`), optionally filtered by User-Agent. Everything else gets a 404.
* Generates a self-signed certificate for the chosen `ServerName` if there is not one already in `/etc/ssl/redirector/`.
* Writes the config, validates the syntax, restarts the service.

The original request path is preserved when forwarded to the backend, so you do not need to rewrite anything on the other side.

## How to run it

You need root, because the script installs packages and writes under `/etc/`.

One-liner straight from GitHub, no cloning required:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Expertware-Security/Redirector/main/redirector-setup.sh)"
```

This works interactively: `curl` fetches the script, `bash -c` runs it with stdin still attached to your terminal, so the prompts keep working. If you would rather inspect it first:

```bash
curl -fsSL https://raw.githubusercontent.com/Expertware-Security/Redirector/main/redirector-setup.sh -o redirector-setup.sh
less redirector-setup.sh
sudo bash redirector-setup.sh
```

Answer the prompts and you are done. If you want to run it non-interactively (from another script or a pipeline), you can feed the answers through stdin in the exact order the script asks for them:

```bash
printf 'nginx\nhttp://10.0.0.20:8080\nmy.host.tld\n80\n443\ntargeted\n/api,/health\nTestAgent\n' \
  | sudo bash redirector-setup.sh
```

Prompt order:
1. Web server (`nginx` or `apache2`)
2. Backend URL
3. ServerName / cert CN
4. HTTP port
5. HTTPS port
6. Mode (`targeted` or `catchall`)
7. (only in `targeted`) Allowed path prefixes, comma separated
8. (only in `targeted`) User-Agent allowlist, comma separated, empty means no filter
9. TLS certificate (`self-signed` or `letsencrypt`, default `self-signed`)
10. (only with `letsencrypt`) Email for renewal and security notices
11. (only with `letsencrypt`) Staging or production (default no, meaning production)

## DNS setup for Let's Encrypt (Azure DNS Zone)

Skip this section if you stick with the self-signed cert. If you pick `letsencrypt`, the ACME HTTP-01 challenge needs your domain to resolve to the redirector's public IPv4, so Let's Encrypt can reach `http://<your-domain>/.well-known/acme-challenge/...` on port 80.

The snippet below is in the [BIND zone file format that Azure DNS imports natively](https://learn.microsoft.com/en-us/azure/dns/dns-import-export-portal). Save it as `example.com.txt`, then in the Azure portal go to `DNS zones > <your zone> > Import`, pick the file, review in the diff viewer, and apply. Azure auto-creates and preserves its own NS and SOA records, so you do not need to include them.

### Subdomain (for example `redir.example.com`)

```text
$ORIGIN example.com.        ; replace example.com with your zone
$TTL 300

redir   IN   A      203.0.113.42        ; replace with the redirector's public IPv4
redir   IN   AAAA   2001:db8::42        ; optional, delete this line if no public IPv6
```

### Apex (`example.com` itself, no subdomain)

```text
$ORIGIN example.com.        ; replace example.com with your zone
$TTL 300

@       IN   A      203.0.113.42        ; replace with the redirector's public IPv4
@       IN   AAAA   2001:db8::42        ; optional, delete this line if no public IPv6
```

You only edit two things: the zone in `$ORIGIN` and the IP after `A` (and the IPv6 line, if you use one).

### Azure CLI alternative

If you prefer the CLI over the portal, same effect in two commands:

```bash
ZONE="example.com"           # the zone you own in Azure DNS
RG="my-resource-group"       # the resource group holding the zone
NAME="redir"                 # subdomain, or "@" for apex
IPV4="203.0.113.42"          # redirector's public IPv4

az network dns record-set a add-record -g "$RG" -z "$ZONE" -n "$NAME" -a "$IPV4" --ttl 300

# Only if you also have public IPv6:
# IPV6="2001:db8::42"
# az network dns record-set aaaa add-record -g "$RG" -z "$ZONE" -n "$NAME" -a "$IPV6" --ttl 300
```

### Verify before running the script with `letsencrypt`

From the redirector itself:

```bash
dig +short A redir.example.com       # should print your IPv4
curl -fsS http://redir.example.com/  # should hit the redirector (200, 404, anything is fine, as long as it lands)
```

If both work, you are ready. Common Azure traps if they do not: NSG inbound port 80 is closed, the VM's public IP is `Dynamic` instead of `Static`, or the zone is not delegated at your registrar (check the NS records in the zone's Overview page).

## How to test it works

The `tests/` folder ships two test suites, both Docker based. Neither of them touches your local machine.

### `tests/run.sh`, the quick single-container suite

Spins up an Ubuntu container, installs `apache2`, `nginx`, `python3`, copies the setup script plus a minimal Python backend, and runs the setup script for each combination of web server and mode. Backend, redirector and curl all live in the same container and talk over `127.0.0.1`. It is fast, but it does not exercise real networking.

```bash
bash tests/run.sh
```

It covers four combinations (`apache2/catchall`, `apache2/targeted`, `nginx/catchall`, `nginx/targeted`), with assertions for HTTP and HTTPS, path preservation, the path allowlist, the User-Agent allowlist, and 404 responses for everything that should not pass through.

### `tests/run-cluster.sh`, the multi-container suite

This one is closer to a real deployment. It creates a Docker network, runs the backend in its own container, the curl client in another, and the redirector in a third one, configured to forward to `http://backend:8080` via Docker's internal DNS. That way the redirector actually talks to a different host over the network instead of to itself.

```bash
bash tests/run-cluster.sh
```

Same matrix of four combinations, plus a sanity check that the client can reach the backend directly.

### Windows notes

On Git Bash, MSYS automatically rewrites paths like `/setup.sh` into `C:/Program Files/Git/setup.sh` when they are passed to `docker exec`. The easiest workaround is to run the suites through WSL:

```powershell
wsl -e bash -c "cd '/mnt/c/Users/<you>/Documents/Custom Projects/Redirector' && bash tests/run.sh"
wsl -e bash -c "cd '/mnt/c/Users/<you>/Documents/Custom Projects/Redirector' && bash tests/run-cluster.sh"
```

On native Linux and macOS the suites run as-is, no extra setup needed.

## Things worth knowing before you use it

* The HTTPS certificate defaults to self-signed, which always works (no DNS, no firewall requirements, no external dependency). When you pick `letsencrypt` at the TLS prompt, the script installs certbot, serves the ACME HTTP-01 challenge from `/var/www/html/.well-known/acme-challenge/` (this passthrough is always present in the config, regardless of mode), runs `certbot certonly --webroot`, then rewrites the config to point to `/etc/letsencrypt/live/<domain>/`. Renewal is wired up automatically through certbot's systemd timer with a reload hook. If issuance fails (DNS does not resolve to this host, port 80 unreachable, rate limited, etc.) the script keeps the self-signed cert and warns, so the box never ends up without HTTPS. Let's Encrypt requires `HTTP port = 80` because the HTTP-01 challenge always validates on port 80; if you pick another port, the script skips issuance and stays on self-signed.
* The Let's Encrypt staging option uses the test CA. Certs are issued instantly and with very high rate limits, but browsers do not trust them (same warning as self-signed). Use it while you are wiring up DNS and verifying the setup, then rerun the script with `n` for the real cert. Production rate limits to watch for: 5 duplicate certs per week, 50 certs per registered domain per week.
* The upstream `Host` header is rewritten to the backend's hostname, not forwarded from the client. This is what you want for CDN-fronted backends like Cloudflare: if Host does not match SNI, Cloudflare answers `421 Misdirected Request`. If you actually need to forward the client's Host (rare, mostly internal vhost setups), edit the generated config and switch `ProxyPreserveHost` to `On` for Apache, or set `proxy_set_header Host $host;` for Nginx.
* In `targeted` mode the path allowlist matches by prefix but is anchored, so `/apifoo` does not match an `/api` entry. That is intentional, to avoid accidentally exposing routes you did not mean to.
* The User-Agent filter is a noise reduction tool, not a security boundary. Anyone who really wants to reach the backend can set the header themselves. It is mostly useful for keeping casual scanners out of the logs.
* The script assumes a Debian or Ubuntu based distribution (it uses `apt-get`). Anything else needs manual tweaks.

## Repo layout

```
redirector-setup.sh        the main script, the only thing that runs on the target
tests/
  Dockerfile               Ubuntu image with apache2, nginx, python3, curl
  backend.py               test backend, echoes path and User-Agent
  run.sh                   single-container test suite
  run-cluster.sh           multi-container test suite
```

The rest (`.gitignore`, README) is repo-only.
