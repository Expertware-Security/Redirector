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

* The HTTPS certificate is self-signed. For anything exposed publicly, replace `/etc/ssl/redirector/redirector.crt` and `redirector.key` with a real one (Let's Encrypt, internal CA, whatever fits) and restart the service.
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
