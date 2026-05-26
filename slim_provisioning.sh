#!/usr/bin/env bash
# teasing-nsfw-comfy SLIM provisioning — runs on vast.ai pod startup.
# Образ уже с 28 custom_nodes + rclone + FileBrowser, тянем только данные.
#
# Что осталось в runtime после миграции на pre-baked image:
#   1. Configure rclone (creds runtime)
#   2. Sync ~99 GB моделей из R2 teasing-nsfw/{animator,xmode}/models/
#   3. Sync workflows из R2 teasing-nsfw/{animator,xmode}/workflows/
#   4. Symlinks для legacy paths (unet/, clip/, ckpt/)
#   5. Restore ComfyUI base files (workspace_init compatibility)
#   6. Init + start FileBrowser
#   7. Restart ComfyUI
#
# Required env vars (set via vast.ai create --env):
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_ENDPOINT
#   R2_BUCKET                 (default: aigirls-comfy)
#   R2_PREFIX                 (default: teasing-nsfw)
#   FB_USER                   (default: admin)
#   FB_PASSWORD               (default: change-me)

set -u
exec > >(tee -a /workspace/provisioning.log) 2>&1

START_TS=$(date +%s)
echo "==========================================="
echo "teasing-nsfw-comfy SLIM provisioning — $(date -Iseconds)"
echo "==========================================="

# --- Paths ---------------------------------------------------------------
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
if [ ! -d "$COMFYUI_DIR" ]; then
  echo "FATAL: ComfyUI not found at $COMFYUI_DIR"
  exit 1
fi

MODELS_DIR="$COMFYUI_DIR/models"
NODES_DIR="$COMFYUI_DIR/custom_nodes"
WORKFLOWS_DIR="$COMFYUI_DIR/user/default/workflows"
R2_BUCKET="${R2_BUCKET:-aigirls-comfy}"
R2_PREFIX="${R2_PREFIX:-teasing-nsfw}"
FB_USER="${FB_USER:-admin}"
FB_PASSWORD="${FB_PASSWORD:-change-me}"

VENV_ACTIVATE="/venv/main/bin/activate"
if [ -f "$VENV_ACTIVATE" ]; then
  . "$VENV_ACTIVATE"
fi

echo "ComfyUI dir : $COMFYUI_DIR"
echo "R2 bucket   : $R2_BUCKET"
echo "R2 prefix   : $R2_PREFIX"
echo "Custom nodes: $(ls "$NODES_DIR" 2>/dev/null | wc -l) baked-in directories"
echo ""

# --- Sanity check env ----------------------------------------------------
if [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ] || [ -z "${R2_ENDPOINT:-}" ]; then
  echo "FATAL: missing R2 env vars (R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT)"
  exit 1
fi

# --- 1. Configure rclone -------------------------------------------------
echo "[1/7] configuring rclone for R2..."
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = $R2_ENDPOINT
region = auto
acl = private
no_check_bucket = true
EOF

if ! rclone ls "r2:$R2_BUCKET" --max-depth 1 >/dev/null 2>&1; then
  echo "FATAL: rclone cannot access r2:$R2_BUCKET — check credentials"
  exit 1
fi
echo "  R2 connection ok"

# --- 2. Pull models from R2 (THE big phase) ------------------------------
# Sync ОБА prefix'а (animator + xmode) → /workspace/ComfyUI/models/
# rclone copy с --update (last-modified wins) для merge — у его двух zip'ов могут
# быть одинаковые имена в разных подпапках, оба нужны.
echo "[2/7] pulling models from R2 ($R2_PREFIX/animator/models, $R2_PREFIX/xmode/models)..."
mkdir -p "$MODELS_DIR"

for sub in animator xmode; do
  echo "  -> $R2_PREFIX/$sub/models/"
  rclone copy "r2:$R2_BUCKET/$R2_PREFIX/$sub/models" "$MODELS_DIR" \
    --transfers 8 --checkers 16 \
    --stats 30s --stats-one-line
done

# --- 3. Model-path compat symlinks --------------------------------------
# Его workflow'ы используют разные пути: unet/, clip/, ckpt/.
# Делаем symlinks из diffusion_models/ и text_encoders/ для совместимости.
echo "[3/7] adding model-path compat symlinks..."
mkdir -p "$MODELS_DIR/unet" "$MODELS_DIR/clip" "$MODELS_DIR/ckpt"
SYMLINKED=0
shopt -s nullglob
for src in "$MODELS_DIR"/diffusion_models/*.safetensors "$MODELS_DIR"/diffusion_models/*.ckpt; do
  name=$(basename "$src")
  dest="$MODELS_DIR/unet/$name"
  [ ! -e "$dest" ] && ln -sf "$src" "$dest" && SYMLINKED=$((SYMLINKED+1))
done
for src in "$MODELS_DIR"/text_encoders/*.safetensors "$MODELS_DIR"/text_encoders/*.ckpt; do
  name=$(basename "$src")
  dest="$MODELS_DIR/clip/$name"
  [ ! -e "$dest" ] && ln -sf "$src" "$dest" && SYMLINKED=$((SYMLINKED+1))
done
# его detect.safetensors в его zip'е лежал в ckpt/ — оставляем как есть, но
# дублируем в checkpoints/ для тех нод что ищут стандартный путь
for src in "$MODELS_DIR"/ckpt/*.safetensors; do
  name=$(basename "$src")
  dest="$MODELS_DIR/checkpoints/$name"
  [ ! -e "$dest" ] && ln -sf "$src" "$dest" && SYMLINKED=$((SYMLINKED+1))
done
shopt -u nullglob
echo "  symlinked $SYMLINKED file(s) for legacy paths"

# --- 4. Pull workflows from R2 ------------------------------------------
echo "[4/7] pulling workflows from R2..."
mkdir -p "$WORKFLOWS_DIR"
for sub in animator xmode; do
  rclone copy "r2:$R2_BUCKET/$R2_PREFIX/$sub/workflows" "$WORKFLOWS_DIR" --transfers 4 --quiet 2>&1 || true
done
echo "  workflows: $(find "$WORKFLOWS_DIR" -name '*.json' 2>/dev/null | wc -l) JSON files"

# --- 5. Restore ComfyUI base files (workspace_init compatibility) -------
# Same trick as redsky-comfy: vastai/comfy base image keeps full ComfyUI в /opt/
# и копирует только если destination пустое. Наш image с custom_nodes ломает это.
if [ ! -f "$COMFYUI_DIR/main.py" ]; then
  echo "[5/9] ComfyUI main.py missing — restoring base files from /opt/workspace-internal..."
  if [ -d /opt/workspace-internal/ComfyUI ]; then
    rsync -a --ignore-existing /opt/workspace-internal/ComfyUI/ "$COMFYUI_DIR/" 2>&1 | tail -5
    if [ -f "$COMFYUI_DIR/main.py" ]; then
      echo "  main.py restored successfully"
    else
      echo "  FATAL: main.py still missing after rsync — vastai/comfy template structure changed?"
      exit 1
    fi
  else
    echo "  FATAL: /opt/workspace-internal/ComfyUI not found — base image structure unexpected"
    exit 1
  fi
else
  echo "[5/9] main.py exists, skipping base restore"
fi

# --- 5b. Pin ComfyUI to v0.8.2 (employee's exact version, revealed in logs) ----
# Employee runs ComfyUI v0.8.2 (revision 4498 2e9d5168 *DETACHED, 2026-01-07).
# In his logs CRT-Nodes/KJNodes also fail import with `_append_guide_attention_entry`
# — это нормально, FancyTimerNode не требуется для исполнения xmode.
# Force /workspace/ComfyUI to v0.8.2 so xmode workflow runs end-to-end.
TARGET_COMFY_TAG="${TARGET_COMFY_TAG:-v0.8.2}"
echo "[5b/9] pinning ComfyUI to $TARGET_COMFY_TAG..."
cd "$COMFYUI_DIR"
if [ -d .git ]; then
  CURRENT_TAG=$(git describe --tags --always 2>/dev/null || echo "unknown")
  echo "  current: $CURRENT_TAG  target: $TARGET_COMFY_TAG"
  if [ "$CURRENT_TAG" != "$TARGET_COMFY_TAG" ]; then
    git fetch --depth=1 origin "refs/tags/$TARGET_COMFY_TAG:refs/tags/$TARGET_COMFY_TAG" 2>&1 | tail -3
    git checkout "$TARGET_COMFY_TAG" 2>&1 | tail -3 || echo "  WARN: checkout failed"
    NEW_TAG=$(git describe --tags --always 2>/dev/null || echo "unknown")
    echo "  now at: $NEW_TAG"
  else
    echo "  already at target"
  fi
else
  echo "  WARN: /workspace/ComfyUI is not a git repo, cannot downgrade — will try anyway"
fi

# --- 5c. Sync employee's custom_nodes from R2 (replace baked ones) ------
# Baked custom_nodes from public GitHub may differ from employee's versions.
# Authoritative source: R2 teasing-nsfw/{animator,xmode}/custom_nodes/
echo "[5c/9] syncing custom_nodes from R2 (employee's versions, replacing baked)..."
for sub in animator xmode; do
  if rclone lsd "r2:$R2_BUCKET/$R2_PREFIX/$sub/custom_nodes" >/dev/null 2>&1; then
    echo "  -> $R2_PREFIX/$sub/custom_nodes/"
    rclone copy "r2:$R2_BUCKET/$R2_PREFIX/$sub/custom_nodes" "$NODES_DIR" \
      --transfers 8 --checkers 16 \
      --stats 30s --stats-one-line \
      --update
  fi
done
echo "  custom_nodes now: $(ls "$NODES_DIR" 2>/dev/null | wc -l) dirs"

# --- 5d. Resolution-Master full replace (R2 ver has no smart_fit arg) ----
# Employee's R2 Resolution-Master is older than what we'd get on overlay copy.
# Newer baked version requires `smart_fit` arg that xmode JSON doesn't provide → crash.
# Force full replace (rm then rclone) instead of overlay merge.
echo "[5d/9] replacing Resolution-Master with R2 employee's version..."
if rclone lsd "r2:$R2_BUCKET/$R2_PREFIX/xmode/custom_nodes/Comfyui-Resolution-Master" >/dev/null 2>&1; then
  rm -rf "$NODES_DIR/Comfyui-Resolution-Master"
  rclone copy "r2:$R2_BUCKET/$R2_PREFIX/xmode/custom_nodes/Comfyui-Resolution-Master/" \
    "$NODES_DIR/Comfyui-Resolution-Master/" --transfers 8 --quiet
  echo "  Resolution-Master replaced ($(find "$NODES_DIR/Comfyui-Resolution-Master" -name '*.py' | wc -l) .py files)"
else
  echo "  WARN: Resolution-Master not in R2, keeping baked version"
fi

# --- 5e0. Stub `_append_guide_attention_entry` in comfy_extras/nodes_lt.py ---
# ComfyUI v0.8.2 doesn't have this function. KJNodes' ltxv_nodes.py imports it
# at top-level → KJNodes import fails → GetImageSizeAndCount/ImageResizeKJv2 don't
# register → animator workflow validation fails ("missing nodes").
# Stub allows KJNodes to import (LTX nodes won't work but xmode/animator не их используют).
NODES_LT="$COMFYUI_DIR/comfy_extras/nodes_lt.py"
if [ -f "$NODES_LT" ] && ! grep -q "_append_guide_attention_entry" "$NODES_LT"; then
  cat >> "$NODES_LT" <<'EOF'


def _append_guide_attention_entry(*args, **kwargs):
    """Stub for KJNodes — not used by xmode/animator workflows."""
    raise NotImplementedError("not available in v0.8.2")
EOF
  echo "[5e0/9] added stub _append_guide_attention_entry in comfy_extras/nodes_lt.py"
fi

# --- 5e. Inject FancyTimer + CRT Post-Process stubs into RES4LYF ---------
# CRT-Nodes import fails on v0.8.2 (taehv missing) — FancyTimerNode + CRT Post-
# Process Suite never register. xmode workflow references both. Stub them in
# RES4LYF/__init__.py (which always loads) so the workflow validates and runs.
# FancyTimer = no-op display, CRT Post = passthrough image. Quality identical to
# employee's setup (his CRT-Nodes also fails the same way per his logs).
echo "[5e/9] injecting FancyTimer + CRT Post stubs into RES4LYF..."
RES4LYF_INIT="$NODES_DIR/RES4LYF/__init__.py"
if [ -f "$RES4LYF_INIT" ] && ! grep -q "BEGIN xmode stubs" "$RES4LYF_INIT"; then
  cat >> "$RES4LYF_INIT" <<'EOF'

# === BEGIN xmode stubs (FancyTimer + CRT Post-Process Suite) ===
class _XmodeFancyTimerNode:
    """No-op stub — original from CRT-Nodes fails import due to LTX23/taehv deps."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {}, "hidden": {"prompt": "PROMPT", "unique_id": "UNIQUE_ID"}}
    RETURN_TYPES = ()
    FUNCTION = "execute"
    OUTPUT_NODE = True
    CATEGORY = "stubs"
    def execute(self, **kwargs): return {}

class _XmodeCRTPostProcessStub:
    """Passthrough stub for CRT Post-Process Suite. Returns input image unchanged."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"image": ("IMAGE",)}, "optional": {}, "hidden": {}}
    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "execute"
    CATEGORY = "stubs"
    def execute(self, image, **kwargs):
        return (image,)

NODE_CLASS_MAPPINGS["FancyTimerNode"] = _XmodeFancyTimerNode
NODE_CLASS_MAPPINGS["CRT Post-Process Suite"] = _XmodeCRTPostProcessStub
NODE_DISPLAY_NAME_MAPPINGS["FancyTimerNode"] = "FancyTimer (stub)"
NODE_DISPLAY_NAME_MAPPINGS["CRT Post-Process Suite"] = "CRT Post (passthrough)"
print("[XMODE STUBS] registered FancyTimerNode + CRT Post-Process Suite")
# === END xmode stubs ===
EOF
  # Clear pycache so the new stubs take effect on next import
  find "$NODES_DIR/RES4LYF" -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
  echo "  stubs injected, pycache cleared"
else
  echo "  RES4LYF __init__.py already has stubs or missing"
fi

# --- 6. FileBrowser ------------------------------------------------------
echo "[6/9] FileBrowser setup..."
if [ ! -f /workspace/.filebrowser.db ]; then
  filebrowser config init --address 0.0.0.0 --port 8090 --root /workspace --database /workspace/.filebrowser.db >/dev/null
  filebrowser users add "$FB_USER" "$FB_PASSWORD" --perm.admin --database /workspace/.filebrowser.db >/dev/null
fi
if ! pgrep -f "filebrowser --database" >/dev/null; then
  nohup filebrowser --database /workspace/.filebrowser.db > /var/log/filebrowser.log 2>&1 &
  disown
fi

# --- 7. Restart ComfyUI --------------------------------------------------
echo "[7/9] restarting ComfyUI..."
if supervisorctl status comfyui >/dev/null 2>&1; then
  supervisorctl restart comfyui 2>&1 || echo "  supervisorctl restart returned non-zero"
else
  pkill -f "python.*main.py" 2>/dev/null || true
fi
sleep 3
if ! pgrep -f "python.*main.py.*--port" >/dev/null && [ -f "$VENV_ACTIVATE" ]; then
  echo "  ComfyUI not running — starting directly..."
  nohup bash -c ". $VENV_ACTIVATE && cd $COMFYUI_DIR && python main.py --listen 0.0.0.0 --port 18188 --enable-cors-header --disable-auto-launch" > /workspace/comfyui.log 2>&1 &
  disown
fi

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
echo ""
echo "==========================================="
echo "teasing-nsfw-comfy provisioning DONE in ${ELAPSED}s"
echo "ComfyUI    : $COMFYUI_DIR"
echo "Models     : $(find "$MODELS_DIR" -type f 2>/dev/null | wc -l) files"
echo "Workflows  : $WORKFLOWS_DIR ($(find "$WORKFLOWS_DIR" -name '*.json' 2>/dev/null | wc -l) files)"
echo "Custom nodes: $(ls "$NODES_DIR" 2>/dev/null | wc -l) (pre-baked)"
echo "==========================================="
