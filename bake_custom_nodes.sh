#!/usr/bin/env bash
# Bake 28 custom_nodes + их pip deps в Docker image для teasing-nsfw pipeline.
# Этот файл копируется в /tmp при сборке и удаляется после выполнения.
#
# Источник списка: union из animator_v2_1_0.json + xmode.json (его GUI workflow'ы).
# Если меняешь — обнови REPORT.md в инвентаре чтобы был синхронизирован.

set -euo pipefail

echo "  pip will install into: $(which pip)"

NODES_DIR="/workspace/ComfyUI/custom_nodes"
mkdir -p "$NODES_DIR"
cd "$NODES_DIR"

# 28 unique custom_nodes из его двух workflow'ов
CUSTOM_NODES=(
  # === animator stack (kijai's WanVideoWrapper + WanAnimatePreprocess) ===
  "https://github.com/kijai/ComfyUI-WanVideoWrapper"
  "https://github.com/kijai/ComfyUI-WanAnimatePreprocess"
  "https://github.com/kijai/ComfyUI-KJNodes"
  "https://github.com/kijai/ComfyUI-segment-anything-2"

  # === xmode stack (z-image firstframe + NSFW detailers) ===
  "https://github.com/ZhiHui6/zhihui_nodes_comfyui"
  "https://github.com/Azornes/Comfyui-Resolution-Master"
  "https://github.com/EllangoK/ComfyUI-post-processing-nodes"
  "https://github.com/TheLustriVA/ComfyUI-Image-Size-Tools"

  # === обе stack'и (impact + detailers + samplers + post) ===
  "https://github.com/ltdrdata/ComfyUI-Impact-Pack"
  "https://github.com/ltdrdata/ComfyUI-Impact-Subpack"
  "https://github.com/ltdrdata/ComfyUI-Manager"
  "https://github.com/ClownsharkBatwing/RES4LYF"
  "https://github.com/Fannovel16/comfyui_controlnet_aux"
  "https://github.com/ainvfx/ComfyUI-SeedVR2_VideoUpscaler"
  "https://github.com/PozzettiAndrea/ComfyUI-SAM3"

  # === utility / UI ===
  "https://github.com/yolain/ComfyUI-Easy-Use"
  "https://github.com/pythongosssss/ComfyUI-Custom-Scripts"
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "https://github.com/cubiq/ComfyUI_essentials"
  "https://github.com/chflame163/ComfyUI_LayerStyle"
  "https://github.com/rgthree/rgthree-comfy"
  "https://github.com/chrisgoringe/cg-use-everywhere"
  "https://github.com/Smirnov75/ComfyUI-mxToolkit"
  "https://github.com/crystian/ComfyUI-Crystools"

  # === teskor (TS-utils: color match, pose smoother, video combine, preview) ===
  "https://github.com/teskor-hub/comfyui-teskors-utils"

  # === post / utility (опциональные, но в его pipeline присутствуют) ===
  "https://github.com/PGCRT/CRT-Nodes"
  "https://github.com/fq393/ComfyUI-ZMG-Nodes"
  "https://github.com/jnxmx/ComfyUI_HuggingFace_Downloader"
)

INSTALLED=0; FAILED=0
for repo in "${CUSTOM_NODES[@]}"; do
  name=$(basename "$repo" .git)
  target="$NODES_DIR/$name"
  echo "  + $name"
  if git clone --depth 1 "$repo" "$target" 2>&1 | tail -1 | sed 's/^/    /'; then
    if [ -f "$target/requirements.txt" ]; then
      pip install --no-cache-dir -r "$target/requirements.txt" 2>&1 | tail -3 | sed 's/^/    /' || \
        echo "    !! pip install failed for $name (продолжаем)"
    fi
    INSTALLED=$((INSTALLED+1))
  else
    echo "    !! git clone failed for $name"
    FAILED=$((FAILED+1))
  fi
done

echo ""
echo "  custom_nodes baked: installed=$INSTALLED failed=$FAILED"

if [ "$FAILED" -gt 0 ]; then
  echo "  WARNING: $FAILED nodes failed during bake. Image still builds но проверь логи."
fi

# Cleanup
find "$NODES_DIR" -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true
echo "  cleaned up .git directories to reduce image size"

rm -rf /root/.cache/pip /var/lib/apt/lists/* 2>/dev/null || true
