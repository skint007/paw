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

`paw` is a thin, repo-scoped shortcut around an AUR helper (it prefers `yay`,
falls back to `paru`; override with `PAW_HELPER=paru`). It's optional sugar —
`yay -Sl paw`, `yay -S <pkg>`, `yay` all work the same.

```
paw                 list packages in the paw repo   (yay -Sl paw)
paw <pkg>           install from paw                 (yay -S paw/<pkg>)
paw search <term>   search the paw repo
paw update          full system upgrade              (yay)
paw remove <pkg>    uninstall                        (yay -Rns <pkg>)
paw info <pkg>      details                          (yay -Si paw/<pkg>)
paw -Ss <term>      anything starting with - is passed straight to the helper
```

Note: packages with AUR dependencies (e.g. clipboard-typer needs `python-pynput`)
install via `yay`/`paru` only — plain `pacman -S` can't resolve the AUR dep.

## Build locally (testing)

On an Arch machine with your key imported:

```bash
bash scripts/build-repo.sh    # produces ./out/ with the signed repo
```

You can point a test `pacman.conf` at `Server = file:///path/to/out` to try it.

## How rebuilds work (incremental)

CI doesn't rebuild every package on every run. Before building, it **restores the
currently published repo** into `out/`, then for each manifest entry it checks the
source repo's HEAD commit with `git ls-remote` (no clone) against `out/state.json`:

- **commit unchanged** → the existing built package is carried forward (no rebuild),
- **commit changed / new package** → it's cloned and rebuilt, replacing the old version,
- **removed from the manifest** → its package is pruned from the repo.

Only changed files are re-uploaded, and stale assets (old versions, removed packages)
are deleted from the release. So pushing one new package builds one package — the rest
are carried forward in seconds.

The commit SHA is an exact proxy for "would the version change?" — any source edit,
`pkgrel` bump, or `-bin` version bump is a commit, so it's always caught. `pkgver()`
still runs during the rebuild to produce the actual version consumers see.

**Triggers:** a push to this repo, **a nightly schedule** (so updates to your package
repos get picked up automatically), or `gh workflow run build-repo` on demand. A run
where nothing changed is a near-instant no-op.

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
