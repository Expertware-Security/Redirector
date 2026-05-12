# Redirector

Un script de setup interactiv care transformă o mașină Linux într-un reverse proxy peste Apache2 sau Nginx. Scopul lui e simplu: pui un domeniu sau un IP în față, trimiți traficul mai departe către un backend real, iar tu decizi dacă orice cerere merge prin sau doar cele care arată "OK" (path-uri permise, opțional și un filtru de User-Agent). Pe ce nu se potrivește, se răspunde cu 404 ca și cum nimic nu există acolo.

E gândit pentru situații de tip operator: vrei să expui un backend printr-o cutie intermediară, dar nu vrei ca scannerele și vizitatorii întâmplători să vadă mai mult decât trebuie. HTTP și HTTPS sunt configurate amândouă, cu un certificat self-signed generat local. Dacă ai nevoie de unul real, înlocuiești fișierele din `/etc/ssl/redirector/` după rulare.

## Ce face concret

* Te întreabă ce web server vrei (`nginx` sau `apache2`), instalează ce lipsește.
* Te întreabă către ce backend să trimită (de exemplu `http://10.0.0.20:8080` sau `https://api.intern.local`).
* Te întreabă ce nume de server și ce porturi să folosească (80 / 443 sunt default).
* Te lasă să alegi modul de operare:
  * `catchall` proxy-ează absolut orice cerere.
  * `targeted` proxy-ează doar path-urile pe care le treci în allowlist (ex. `/api,/health`) și opțional doar dacă User-Agent-ul conține una din etichetele acceptate. Restul primesc 404.
* Generează un cert self-signed pentru `ServerName` dacă nu există deja unul în `/etc/ssl/redirector/`.
* Scrie config-ul, validează sintaxa, repornește serviciul.

Path-ul original al cererii se păstrează când e trimisă către backend, ca să nu trebuiască să mai potrivești manual la celălalt capăt.

## Cum rulezi

Trebuie root, pentru că instalează pachete și scrie în `/etc/`.

One-liner direct de pe GitHub, fără să trebuiască să clonezi nimic:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Expertware-Security/Redirector/main/redirector-setup.sh)"
```

Funcționează interactiv: `curl` aduce scriptul, `bash -c` îl execută cu stdin-ul tot pe terminal, așa că prompt-urile rămân funcționale. Dacă preferi să te uiți peste el înainte:

```bash
curl -fsSL https://raw.githubusercontent.com/Expertware-Security/Redirector/main/redirector-setup.sh -o redirector-setup.sh
less redirector-setup.sh
sudo bash redirector-setup.sh
```

Răspunzi la prompt-uri și gata. Dacă vrei să rulezi neinteractiv (de exemplu dintr-un alt script sau dintr-un pipeline), îi poți alimenta răspunsurile prin stdin în ordinea în care sunt cerute:

```bash
printf 'nginx\nhttp://10.0.0.20:8080\nmy.host.tld\n80\n443\ntargeted\n/api,/health\nTestAgent\n' \
  | sudo bash redirector-setup.sh
```

Ordinea prompt-urilor:
1. Web server (`nginx` sau `apache2`)
2. URL backend
3. ServerName / CN pentru cert
4. Port HTTP
5. Port HTTPS
6. Mod (`targeted` sau `catchall`)
7. (doar în `targeted`) Path-uri permise, separate prin virgulă
8. (doar în `targeted`) User-Agent allowlist, separat prin virgulă, gol înseamnă fără filtru

## Cum testezi că merge

În folderul `tests/` sunt două suite, ambele pe Docker. Niciuna nu îți atinge mașina locală.

### `tests/run.sh` – test rapid, un singur container

Pornește un container Ubuntu, instalează `apache2`, `nginx`, `python3`, copiază scriptul de setup și un backend minimal scris în Python, apoi rulează scriptul pentru fiecare combinație de web server și mod. Backend, redirector și curl trăiesc toate în același container și vorbesc pe `127.0.0.1`. E rapid, dar nu trece pe rețea reală.

```bash
bash tests/run.sh
```

Acoperă 4 combinații (`apache2/catchall`, `apache2/targeted`, `nginx/catchall`, `nginx/targeted`), cu asserții pe HTTP și HTTPS, păstrarea path-ului, allowlist de path, allowlist de User-Agent, plus respingerea cu 404 pe ce nu trebuie să treacă.

### `tests/run-cluster.sh` – test multi-container

Acesta e mai aproape de realitate. Creează o rețea Docker, pornește backend-ul într-un container separat, clientul de curl în alt container, iar redirectorul într-un al treilea container, configurat să trimită către `http://backend:8080` prin DNS-ul Docker. Asta verifică efectiv că redirectorul vorbește peste rețea cu un alt host, nu cu el însuși.

```bash
bash tests/run-cluster.sh
```

Aceeași matrice de 4 combinații, plus un sanity check că clientul ajunge direct la backend.

### Note pentru Windows

Pe Git Bash, MSYS rescrie automat path-urile gen `/setup.sh` în `C:/Program Files/Git/setup.sh` când le pasează către `docker exec`. Cea mai simplă variantă e să rulezi suitele prin WSL:

```powershell
wsl -e bash -c "cd '/mnt/c/Users/<tu>/Documents/Custom Projects/Redirector' && bash tests/run.sh"
wsl -e bash -c "cd '/mnt/c/Users/<tu>/Documents/Custom Projects/Redirector' && bash tests/run-cluster.sh"
```

Pe Linux nativ și pe macOS, suitele rulează direct fără nimic în plus.

## Ce ar trebui să știi înainte să folosești

* Certificatul HTTPS e self-signed. Pentru ceva expus public, înlocuiește `/etc/ssl/redirector/redirector.crt` și `redirector.key` cu un cert valid (Let's Encrypt, intern, oricum vrei tu) și repornește serviciul.
* În modul `targeted`, allowlist-ul de path-uri se face pe prefix, dar e ancorat (nu se potrivește `/apifoo` când ai pus `/api`). Asta e intenționat, ca să nu scapi accidental rute pe care nu le vrei expuse.
* Filtrul de User-Agent e o protecție de ramură, nu un mecanism de securitate. Cine vrea cu adevărat să ajungă la backend își setează singur header-ul. E util mai mult ca filtru anti-zgomot.
* Scriptul presupune o distribuție Debian sau Ubuntu (folosește `apt-get`). Pe altceva trebuie ajustat la mână.

## Structura repo-ului

```
redirector-setup.sh        scriptul principal, singurul care merge pe target
tests/
  Dockerfile               imagine Ubuntu cu apache2, nginx, python3, curl
  backend.py               backend de test, returnează path și User-Agent
  run.sh                   suita rapidă (single-container)
  run-cluster.sh           suita multi-container
```

Restul (`.gitignore`, README) sunt doar pentru repo.
