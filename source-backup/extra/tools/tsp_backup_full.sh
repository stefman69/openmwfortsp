#!/bin/bash
# tsp_backup_full.sh - full source backup of the port to GitHub (stefman69/openmwfortsp, branch source-backup).
# Runs on the host VM (bob-simpson). Wraps the existing stager (~/tsp_source_backup.sh) and adds what it never knew about:
#   - the game manager source (auto-found on the VM and in the openmw_builder container, plus ~/tsp_backup_extra.txt)
#   - every tool and patch in ~/Downloads (*.sh *.patch *.awk) and the launcher copies pulled by tsp_ship.sh compare
# Modes:
#   bash ~/Downloads/tsp_backup_full.sh          stage (restage if older than TSP_MAXAGE, default 3600 s) + extras + push
#   bash ~/Downloads/tsp_backup_full.sh list     stage + extras, show what would go up, push nothing
#   TSP_FORCE_STAGE=1 bash ~/Downloads/tsp_backup_full.sh     force a fresh capture
# Token: read from ~/.tsp_github_token (mode 600) - never on the command line, never in this file, never in the chat:
#   printf '%s\n' 'ghp_...' > ~/.tsp_github_token && chmod 600 ~/.tsp_github_token
# Extras list ~/tsp_backup_extra.txt, one per line:  /path/on/vm   docker:/root/path/in/container   -name-to-skip
# Skipped inside extras: .git, build*/, *.o *.a *.so *.tar.gz, and any single file over 50 MB (GitHub refuses 100 MB).

set -uo pipefail
MODE="${1:-push}"
GH_USER="stefman69"; GH_REPO="openmwfortsp"; BR="source-backup"
STAGE="$HOME/tsp-source-backup"
REPO_DIR="$HOME/tsp-source-backup-repo"
MAXAGE="${TSP_MAXAGE:-3600}"
STAMP="$(date +%Y%m%d-%H%M%S)"
MAN="$STAGE/manifests/SHA256SUMS.txt"
EXTRA="$STAGE/extra"
EXTRA_LIST="$HOME/tsp_backup_extra.txt"
TOKEN_FILE="$HOME/.tsp_github_token"
CONTAINER=openmw_builder
DOCKER=docker; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
hdr(){ printf '\n=== %s ===\n' "$*"; }
say(){ printf '  %s\n' "$*"; }

# ---------------------------------------------------------------- 1. their stager, unchanged
hdr "1. staged snapshot at $STAGE"
NOW="$(date +%s)"; AGE=-1
if [ -f "$MAN" ]; then MT="$(stat -c %Y "$MAN")"; AGE=$(( NOW - MT )); say "staged $(( AGE / 60 )) min ago ($(grep -c . "$MAN") files in the manifest)"; else say "no staged snapshot yet"; fi
if [ "$AGE" -lt 0 ] || [ "$AGE" -ge "$MAXAGE" ] || [ "${TSP_FORCE_STAGE:-0}" = "1" ]; then
    if [ -f "$HOME/tsp_source_backup.sh" ]; then
        hdr "2. restaging with ~/tsp_source_backup.sh (stale, missing or forced)"
        bash "$HOME/tsp_source_backup.sh"
        [ -f "$MAN" ] || { say "staging produced no manifest - refusing to push"; exit 1; }
    else
        say "!! ~/tsp_source_backup.sh is missing - only the extras below will be staged"; mkdir -p "$STAGE/manifests"
    fi
else
    hdr "2. snapshot under $(( MAXAGE / 60 )) min old - capture skipped (TSP_FORCE_STAGE=1 to force)"
fi

# ---------------------------------------------------------------- 3. extras: manager source, tools, launchers
hdr "3. extras -> $EXTRA"
rm -rf "$EXTRA"; mkdir -p "$EXTRA/tools" "$EXTRA/launchers" "$EXTRA/manager"
copy_tree() {   # copy_tree <src-dir> <dst-dir>  with the exclusions above; prints what it kept
    local src="$1" dst="$2" n=0 skipped=0
    mkdir -p "$dst"
    while IFS= read -r -d '' f; do
        rel="${f#$src/}"
        case "/$rel" in */.git/*|*/build*/*|*.o|*.a|*.so|*.so.*|*.tar.gz|*.tgz|*.zip) skipped=$((skipped+1)); continue ;; esac
        if [ "$(stat -c %s "$f")" -gt 52428800 ]; then say "    skip >50MB: $rel"; skipped=$((skipped+1)); continue; fi
        mkdir -p "$dst/$(dirname "$rel")"; cp -p "$f" "$dst/$rel"; n=$((n+1))
    done < <(find "$src" -type f -print0 2>/dev/null)
    say "  $src -> $dst : $n files ($(du -sh "$dst" 2>/dev/null | cut -f1)), $skipped skipped"
}
# 3a. tools and patches from ~/Downloads, launcher copies from tsp_ship.sh compare
for f in "$HOME"/Downloads/*.sh "$HOME"/Downloads/*.patch "$HOME"/Downloads/*.awk; do [ -f "$f" ] && cp -p "$f" "$EXTRA/tools/"; done
say "tools: $(ls "$EXTRA/tools" | wc -l) files from ~/Downloads (*.sh *.patch *.awk)"
if [ -d "$HOME/Downloads/tsp_ship" ]; then cp -a "$HOME/Downloads/tsp_ship/." "$EXTRA/launchers/"; say "launchers: $(find "$EXTRA/launchers" -name Morrowind.sh | wc -l) card copies from ~/Downloads/tsp_ship"; else say "launchers: none (run  sh ~/Downloads/tsp_ship.sh  first to capture both cards' Morrowind.sh)"; fi
# 3b. manager source: discovered + listed
CANDS=""
while IFS= read -r d; do CANDS="$CANDS"$'\n'"vm:$d"; done < <(find "$HOME" -maxdepth 3 -type d \( -iname '*manager*' -o -iname '*navmesh-progress*' -o -iname '*navmeshtool*' \) -not -path '*/.*' -not -path "$STAGE*" -not -path "$REPO_DIR*" 2>/dev/null)
if $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    while IFS= read -r d; do [ -n "$d" ] && CANDS="$CANDS"$'\n'"docker:$d"; done < <($DOCKER exec "$CONTAINER" sh -c "find /root -maxdepth 2 -type d \( -iname '*manager*' -o -iname '*navmesh-progress*' -o -iname '*navmeshtool*' \) 2>/dev/null")
else
    say "container $CONTAINER not running - container-side sources not searched (start it and re-run for those)"
fi
[ -f "$EXTRA_LIST" ] && while IFS= read -r l; do case "$l" in ''|'#'*) ;; *) CANDS="$CANDS"$'\n'"$l" ;; esac; done < "$EXTRA_LIST"
SKIP=$(printf '%s\n' "$CANDS" | grep '^-' | sed 's/^-//')
say "manager/tool source candidates:"
printf '%s\n' "$CANDS" | grep -v '^-' | grep . | sort -u | while IFS= read -r c; do
    name="$(basename "${c#*:}")"
    if printf '%s\n' "$SKIP" | grep -qx "$name"; then say "  - $c (skipped by $EXTRA_LIST)"; continue; fi
    case "$c" in
        docker:*) src="${c#docker:}"; tmp="$(mktemp -d)"; if $DOCKER cp "$CONTAINER:$src" "$tmp/" 2>/dev/null; then copy_tree "$tmp/$name" "$EXTRA/manager/$name"; else say "  !! docker cp failed for $src"; fi; rm -rf "$tmp" ;;
        vm:*|/*) src="${c#vm:}"; [ -d "$src" ] && copy_tree "$src" "$EXTRA/manager/$name" || say "  !! not a directory: $src" ;;
    esac
done
[ -f "$EXTRA_LIST" ] || { printf '# tsp_backup_full.sh extras - one per line: /path/on/vm  docker:/root/path  -name-to-skip\n' > "$EXTRA_LIST"; say "created $EXTRA_LIST (add manager source paths there if the search above missed them)"; }
( cd "$EXTRA" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$STAGE/manifests/SHA256SUMS-extra.txt" 2>/dev/null
say "extra total: $(du -sh "$EXTRA" | cut -f1), manifest $STAGE/manifests/SHA256SUMS-extra.txt ($(grep -c . "$STAGE/manifests/SHA256SUMS-extra.txt") files)"
BIG=$(find "$STAGE" -type f -size +95M 2>/dev/null); [ -n "$BIG" ] && { say "!! files over GitHub's 100 MB limit are in the stage - the push will be refused:"; printf '%s\n' "$BIG" | sed 's/^/    /'; }

if [ "$MODE" = list ]; then hdr "list mode - nothing pushed"; find "$EXTRA" -maxdepth 2 | sed 's/^/  /' | head -40; exit 0; fi

# ---------------------------------------------------------------- 4. push (token from the file only)
hdr "4. push to https://github.com/$GH_USER/$GH_REPO/tree/$BR"
[ -s "$TOKEN_FILE" ] || { say "!! no token file. Create a NEW token at github.com/settings/tokens (repo scope), then:"; say "   printf '%s\\n' 'ghp_...' > ~/.tsp_github_token && chmod 600 ~/.tsp_github_token"; exit 1; }
[ "$(stat -c %a "$TOKEN_FILE")" = 600 ] || chmod 600 "$TOKEN_FILE"
GITHUB_TOKEN="$(head -n1 "$TOKEN_FILE" | tr -d '[:space:]')"
AUTH_URL="https://$GH_USER:$GITHUB_TOKEN@github.com/$GH_USER/$GH_REPO.git"
if [ ! -d "$REPO_DIR/.git" ]; then
    rm -rf "$REPO_DIR"
    git clone -q "$AUTH_URL" "$REPO_DIR" || { say "clone failed - check the token (needs repo scope)"; exit 1; }
else
    git -C "$REPO_DIR" remote set-url origin "$AUTH_URL"
    git -C "$REPO_DIR" fetch -q origin 2>/dev/null
fi
git -C "$REPO_DIR" checkout -q "$BR" 2>/dev/null || git -C "$REPO_DIR" checkout -q -b "$BR"
git -C "$REPO_DIR" pull -q --rebase origin "$BR" 2>/dev/null
rm -rf "$REPO_DIR/source-backup"; mkdir -p "$REPO_DIR/source-backup"
cp -a "$STAGE/." "$REPO_DIR/source-backup/"
cp -f "$STAGE/README.md" "$REPO_DIR/README-tsp-port.md" 2>/dev/null
cd "$REPO_DIR" || { say "cannot enter $REPO_DIR"; exit 1; }
git add -A
hdr "5. what is going up"
git diff --cached --stat | tail -25
CHANGED="$(git diff --cached --numstat | grep -c .)"
say "$CHANGED changed files"
if [ "$CHANGED" -eq 0 ]; then
    say "nothing changed since the last push - nothing to do"
else
    git -c user.email="simantonstefan@gmail.com" -c user.name="Steve" commit -q -m "TSP source snapshot $STAMP (stage + manager/tools/launchers extras)"
    if git push -q origin "$BR"; then say "pushed to https://github.com/$GH_USER/$GH_REPO/tree/$BR"; else say "PUSH FAILED"; fi
fi
git remote set-url origin "https://github.com/$GH_USER/$GH_REPO.git"
say "token cleared from the remote URL"
git log --oneline -3
