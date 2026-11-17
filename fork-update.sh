#!/usr/bin/env bash
# Fork AlexandreL04/Handy : remet le patch « pilule compacte » sur la dernière
# version officielle de cjpais/Handy, recompile le .deb et l'installe.
#
#   ./fork-update.sh            # dernière release officielle
#   ./fork-update.sh v0.10.2    # une version précise
#
# Le patch = src/overlay/compact.css + 1 ligne d'import dans
# RecordingOverlay.tsx + ce script : les conflits devraient rester rares.
set -euo pipefail
cd "$(dirname "$0")"

BRANCH=compact-overlay
[ "$(git branch --show-current)" = "$BRANCH" ] || { echo "Pas sur la branche $BRANCH" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Arbre de travail pas propre, commit ou stash d'abord" >&2; exit 1; }

git fetch upstream --tags --quiet
TARGET=${1:-$(gh release view --repo cjpais/Handy --json tagName -q .tagName)}
CURRENT=$(git describe --tags --abbrev=0 --match 'v*' HEAD)

if [ "$CURRENT" != "$TARGET" ]; then
  echo "→ Patch déplacé de $CURRENT vers $TARGET"
  if ! git rebase --onto "$TARGET" "$CURRENT" "$BRANCH"; then
    echo "Conflit : résous-le (git status), puis 'git rebase --continue' et relance le script." >&2
    exit 1
  fi
  git push --force-with-lease origin "$BRANCH"
else
  echo "→ Déjà sur $TARGET, simple recompilation"
fi

# Modèle VAD embarqué dans le bundle (voir AGENTS.md).
VAD=src-tauri/resources/models/silero-vad-v6.2-F32.gguf
[ -f "$VAD" ] || curl -fL -o "$VAD" https://huggingface.co/handy-computer/silero-vad-v6.2-gguf/resolve/main/silero-vad-v6.2-F32.gguf

# Build rapide : le profil release officiel (lto = true, codegen-units = 1)
# fait l'optimisation finale sur un seul cœur. On le surcharge par variables
# d'environnement, sans toucher à Cargo.toml (pas de conflit au rebase).
# Binaire un peu plus gros ; la vitesse de transcription ne change pas (elle
# vient du C++ de transcribe-cpp, compilé à part). Le cache src-tauri/target
# est gardé d'un build à l'autre : seul ce qui change est recompilé.
export CARGO_PROFILE_RELEASE_LTO=false
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
export CMAKE_BUILD_PARALLEL_LEVEL=$(nproc)

bun install --frozen-lockfile
# Sans clé de signature on ne produit pas les artefacts de l'updater officiel.
bun run tauri build --bundles deb --config '{"bundle":{"createUpdaterArtifacts":false}}'

DEB=$(ls -t src-tauri/target/release/bundle/deb/*.deb | head -1)
echo "→ Installation de $DEB"
# Fenêtre de mot de passe KDE quand SUDO_ASKPASS est défini (sessions sans terminal).
sudo ${SUDO_ASKPASS:+-A} apt install -y --reinstall "./$DEB"

if pgrep -x handy >/dev/null; then
  pkill -x handy || true
  sleep 1
fi
# L'updater intégré installerait la version officielle par-dessus le fork.
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path.home() / ".local/share/com.pais.handy/settings_store.json"
if p.exists():
    d = json.loads(p.read_text())
    s = d.get("settings", d)
    if s.get("update_checks_enabled") is not False:
        s["update_checks_enabled"] = False
        p.write_text(json.dumps(d, indent=2))
        print("→ Vérification des mises à jour officielles coupée")
EOF
setsid handy --start-hidden >/dev/null 2>&1 < /dev/null &
echo "✓ Handy $TARGET (fork compact) installé et relancé"
