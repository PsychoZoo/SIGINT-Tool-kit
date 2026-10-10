# SIGINT Tool-kit Guide

Step by step: set up a master, flash ready-to-run nodes, and reach the
dashboard on the master itself or from anywhere.

This guide is in two places with the same content:

- **Online:** `docs/GUIDE.md` in the GitHub repository.
- **Offline:** `http://localhost:8080/guide` on the master. It works with no internet.

## How it fits together

- **The master** (one machine, e.g. a desktop) keeps the database and the
  dashboard. Every node sends what it collects there.
- **Nodes** (Raspberry Pis, spare PCs) run programs: radios, Wi-Fi monitoring,
  the demo simulator. Each node has its own login to the master.
- Nodes reach the master over your **local network**, or from anywhere through
  **Cloudflare**. If the link drops, a node keeps collecting and sends
  everything when it's back, with the original times.

## 1. Set up the master

You need a Linux machine (Arch/Omarchy, Debian, Ubuntu or similar) with this
repository on it:

```bash
git clone https://github.com/PsychoZoo/SIGINT-Tool-kit.git ~/SIGINT-Tool-kit
cd ~/SIGINT-Tool-kit
./toolkit.sh setup
```

Setup:

1. Installs Docker if it's missing (asks for your password; you may need to log
   out and back in once afterwards).
2. Asks for a name for the master and which programs it runs itself
   (`demo` makes fake data, handy for a first test).
3. Asks whether nodes should also connect **through Cloudflare** and whether
   the **dashboard** should be reachable from anywhere. Answer no for now if
   you're not sure: you can run setup again any time.
4. Starts everything and offers to flash nodes (next step).

Every question defaults to the current setting, so running setup again is safe.

## 2. Flash nodes

```bash
./toolkit.sh flash-node
```

It asks:

| Question | What to answer |
|---|---|
| Device type | `pi` for a Raspberry Pi 3, 4, 5 or Zero 2 W; `pc` for an x86-64 PC |
| Node name | Accept the suggestion (`pi-1`, `pi-2`, ...) or type one |
| Programs | `demo` for a first test; later e.g. `adsb ism` (radios need an RTL-SDR each) |
| Wi-Fi | Network name, password, country code. Leave the name empty for Ethernet only |
| SSH key | Accept the default: a key just for nodes, `~/.ssh/sigint_nodes`, made the first time |
| Card or drive | Pick it from the list, then type its name to confirm |

Your answers are remembered. At the end it offers to **flash another** node
with the same settings: swap the card and say yes.

What happens next:

- **Raspberry Pi:** put the card in and power it on.
- **PC:** boot it from the USB drive (boot menu key: often F12, F11, F8 or Esc).
  It **erases the PC's internal disk**, installs, and powers off. Remove the
  drive, then power it on.
  - It only installs on a PC with exactly one internal disk, and refuses a disk
    that already holds a node, so a drive left plugged in can't reinstall.

The first start needs internet once and takes 10 to 20 minutes: the node
installs Docker and its programs. After that it starts by itself on every boot.

## 3. Check it's working

On the master:

```bash
./toolkit.sh nodes     # every node, online or offline
./toolkit.sh status    # what's running on the master
```

Then open the dashboard: `http://localhost:8080` on the master.

## 4. The dashboard

### On the master (works offline)

`http://localhost:8080`: live data, nodes and programs. Also on the master,
with no internet needed:

- `http://localhost:8080/guide`: this guide
- `http://localhost:8080/docs`: the API, with a "try it" button for every call

The dashboard has no login of its own, so it only listens on the master
machine itself.

### Reach the dashboard from anywhere

This goes through Cloudflare, which puts its own login in front (Cloudflare
Access), using a Cloudflare Tunnel, so no ports are opened on your network.
You need a free Cloudflare account and a domain on Cloudflare. (Cloudflare
renames menus from time to time; if a name below doesn't match, look for the
closest one.)

1. **Tunnel.** In the Cloudflare dashboard go to **Zero Trust → Networks →
   Tunnels**. If setup already made one for nodes, use it; otherwise create one
   (connector type *cloudflared*) and give its token to `./toolkit.sh setup`.
2. **Hostname.** On the tunnel, add a **public hostname** (also called a
   published application route), e.g. `sigint.example.com`, service type
   **HTTP**, URL **`api-public:8080`**. Cloudflare creates the DNS record for it.
3. **Login.** Go to **Zero Trust → Access → Applications → Add an application
   → Self-hosted**. Application domain: the hostname from step 2, the whole
   hostname (no path). Add a policy that allows only you (e.g. *Emails* = your
   address). The session duration there is how often you log in again.
4. **Tell the master.** From the application's overview copy the
   **Application Audience (AUD) Tag** (a long string of letters and digits). Your **team domain** is
   `<your-team>.cloudflareaccess.com` (shown in Zero Trust under Settings). Run
   `./toolkit.sh setup` again and answer yes to "Reach the dashboard from the
   internet", or set these in `.env` and run `./toolkit.sh up`:

   ```ini
   CF_ACCESS_TEAM_DOMAIN=your-team.cloudflareaccess.com
   CF_ACCESS_AUD=<the AUD tag>
   DASHBOARD_CLOUDFLARE_HOSTNAME=sigint.example.com
   ```

5. Open `https://sigint.example.com` from anywhere, e.g. your phone off Wi-Fi.
   Cloudflare asks you to log in, then the dashboard opens.

The tunnel only reaches `api-public`, a copy of the API that checks every
request for a valid Cloudflare Access login itself. If step 3 or 4 is missing or
wrong, the page says "Cloudflare Access login required" and shows nothing. The
dashboard on the master itself (`localhost:8080`) needs no login and can't be
reached through the tunnel.

## 5. Without internet

| | Works offline? |
|---|---|
| Dashboard, guide and API docs on the master | Yes |
| Nodes collecting data | Yes; a node stores what it collects and sends it when the link is back |
| Nodes on the same local network as the master | Yes |
| Dashboard from anywhere / nodes through Cloudflare | No; they need the internet |
| Flashing a node | Yes, once the base system has been downloaded (cached in `images/cache/`) |
| A node's very first start | No; it downloads Docker and its programs once |

## 6. Troubleshooting

| Problem | Check |
|---|---|
| A new node never shows up | On the node: `journalctl -u sigint-firstboot` (or `/var/log/sigint-firstboot.log`). Usually no internet, or wrong Wi-Fi password or country |
| A node shows offline | `./toolkit.sh logs broker` on the node and the master. Can the node reach the master's address on port 1884? |
| PC install stopped with "Failed to run preseeded command" | Press Alt+F4 to read why: several internal disks, no internal disk, or the disk already holds a node (remove the drive and restart) |
| "Cloudflare Access isn't set up on this master" | Step 4 of [Reach the dashboard from anywhere](#reach-the-dashboard-from-anywhere) |
| "No Cloudflare Access login on this request" | Step 3: the hostname has no Access application or policy |
| Log in to a node | `ssh -i ~/.ssh/sigint_nodes sigint@<node-name>.local` |

## 7. Lost or stolen device

A card or drive holds that node's login and your Wi-Fi password. Revoke the
node right away:

```bash
./toolkit.sh remove-node <name>
```

Its data is kept. If nodes connect through Cloudflare Access with a service
token, rotate that token in Cloudflare too. Changing the Wi-Fi password is
wise as well.
