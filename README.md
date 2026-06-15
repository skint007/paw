# paw — a personal pacman repository

`paw` is a tiny system for sharing your own Arch packages with friends and
family without putting them on the AUR. You maintain a list of package git
repos; CI builds and signs them into a real pacman repository hosted on GitHub
Releases. Friends add the repo once, then install with a friendly gum TUI and
get updates through normal `pacman -Syu`.

## How it works

```
  packages.json          (you: list of package git repos)
        │
        ▼
  GitHub Actions ──► makepkg --sign ──► repo-add ──► GitHub Release ("repo" tag)
        │                                                  │
        │                                       paw.db + *.pkg.tar.zst + paw.pub
        ▼                                                  │
  friends run install.sh ──► adds [paw] to pacman.conf ◄───┘
        │
        ▼
  paw  (gum TUI over `pacman -Sl paw`) · pacman -Syu for updates
```

Two sides:

- **Maintainer (you):** edit `packages.json`, push, CI publishes a signed repo.
- **Consumer (friends):** run `install.sh`, then use `paw`.

Because it's a true pacman repo, updates are native (`pacman -Syu`), signed, and
fast — no compiling on their end.

---

## Maintainer setup (once)

1. **Create a signing key**

   ```bash
   gpg --full-generate-key                 # ed25519 or RSA 4096
   gpg --list-secret-keys --keyid-format=long   # note the long key id
   ```

2. **Fill in config.** Edit `paw.conf` and the matching constants at the top of
   `install.sh`:
   - `PAW_GH_REPO`  → `youruser/yourrepo`
   - `PAW_GPG_KEYID` → your long key id
   - (`PAW_RELEASE_TAG`, `PAW_REPO_NAME` are fine as defaults)

3. **Add the CI secret.** Export the *private* key and store it as a repo secret
   named `GPG_PRIVATE_KEY`:

   ```bash
   gpg --export-secret-keys --armor YOUR_KEY_ID   # paste into the secret
   ```

4. **Push to GitHub.** From this directory:

   ```bash
   git init && git add -A && git commit -m "init paw"
   git branch -M main
   git remote add origin git@github.com:youruser/yourrepo.git
   git push -u origin main
   ```

   The workflow runs, builds everything, and creates the `repo` release.

## Adding a package

Each package is a normal git repo containing a `PKGBUILD` (a `-git` or `-bin`
PKGBUILD both work — the `aur-package` skill can scaffold these).

```bash
scripts/add-package.sh        # interactive
# or edit packages.json by hand, then:
git commit -am "add foo" && git push
```

CI rebuilds and republishes on every push that touches `packages.json`.

## Consumer setup (friends)

```bash
curl -fsSL https://raw.githubusercontent.com/youruser/yourrepo/main/install.sh | bash
paw
```

That imports your key, adds `[paw]` to `pacman.conf`, and installs `paw`.

## Using paw

```
paw                 browse & install (TUI)
paw <pkg>           install
paw search <term>   search
paw update          sync & upgrade (pacman -Syu)
paw remove <pkg>    uninstall
paw list            installed paw packages
paw info <pkg>      details
```

## Build locally (testing)

On an Arch machine with your key imported:

```bash
bash scripts/build-repo.sh    # produces ./out/ with the signed repo
```

You can point a test `pacman.conf` at `Server = file:///path/to/out` to try it.

---

## Notes & caveats

- **Security model:** these are your packages, signed with your key, shared with
  people who trust you. Friends grant local trust to your key during install.
- **Hosting:** GitHub Releases is free and works well for a personal repo. If
  you outgrow it, point `Server` at any static host that serves `out/`.
- **Untested in this environment:** these scripts target Arch + GitHub Actions;
  run them on a real machine and adjust as needed (the CI GPG/container steps in
  particular are the most likely to need a tweak on first run).
- **Source-build alternative:** if you ever want the yay-style "build from git
  on each machine" flow instead, the manifest already carries the git URLs — a
  helper could clone + `makepkg -si` directly. The binary repo was chosen here
  for the better friend/family UX.
