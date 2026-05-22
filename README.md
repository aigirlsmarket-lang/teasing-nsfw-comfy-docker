# teasing-nsfw-comfy-docker

Pre-baked vast.ai ComfyUI image для teasing-nsfw pipeline (X mode firstframe + animator).

Параллельный проект к [redsky-comfy-docker](https://github.com/aigirlsmarket-lang/redsky-comfy-docker) — те же принципы, разные workflow'ы.

## Что внутри

База `vastai/comfy:v0.19.3-cuda-12.9-py312` + дополнительно забакано:

- **28 custom_nodes** (union из его animator + xmode workflow'ов) + их pip deps
- **rclone** (для R2 sync моделей в runtime)
- **FileBrowser** (для просмотра output'ов через web UI)

**НЕ забакано** (тянется в runtime через `slim_provisioning.sh`):
- ~99 GB моделей с R2 prefix `aigirls-comfy/teasing-nsfw/{animator,xmode}/models/`
- workflows с R2 (`teasing-nsfw/{animator,xmode}/workflows/`)

## Принципы (важно — не нарушать)

**Workflow inputs inviolable.** Никакие inputs нод, scaler'ы, model paths, LoRA strength values, sampler params — НЕ ИЗМЕНЯЮТСЯ. Финальный результат должен быть идентичен тому что собирает сотрудник в своём ComfyUI.

Обход missing custom_nodes — через расширение bake-списка в `bake_custom_nodes.sh`, НЕ через правку workflow JSON.

## R2 структура

```
aigirls-comfy/
  teasing-nsfw/
    animator/
      custom_nodes/   (его 23 ноды как backup, не используется в provisioning)
      models/         (40.9 GiB — Wan2.x stack)
      workflows/      (animator_v2_1_0.json + mask_mode вариант)
    xmode/
      custom_nodes/   (его 23 ноды как backup)
      models/         (58.1 GiB — Z-Image firstframe + NSFW detailers)
      workflows/      (xmode.json)
```

Custom_nodes из R2 — резервная копия для refer'а; image бакает ноды напрямую с GitHub через `bake_custom_nodes.sh`. Если в будущем нужна гарантия побайтовой идентичности — переключаемся на R2 sync custom_nodes (медленнее cold start, но guaranteed identical).

## Использование

### На vast.ai (production)

```bash
# Pod env vars:
IMAGE=<dockerhub-username>/teasing-nsfw-comfy:latest
PROVISIONING_SCRIPT=https://raw.githubusercontent.com/aigirlsmarket-lang/teasing-nsfw-comfy-docker/main/slim_provisioning.sh
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_ENDPOINT=https://b7a8c440c7778d01a7dd4ed3051e9061.r2.cloudflarestorage.com
R2_BUCKET=aigirls-comfy
R2_PREFIX=teasing-nsfw
```

## CI / Build

Автоматически через GitHub Actions на каждый push в `main` который трогает `Dockerfile` или `bake_custom_nodes.sh`.

**One-time setup в новом repo:**

1. GitHub repo secrets (Settings → Secrets and variables → Actions → New repository secret):
   - `DOCKERHUB_USERNAME` — твой DockerHub username
   - `DOCKERHUB_TOKEN` — Access Token из DockerHub (scope: Read/Write/Delete)
2. После push'а в main: смотри Actions tab → должен идти build (~20-30 мин из-за +10 нод vs redsky)

## Связанное

- **R2 bucket**: `aigirls-comfy/teasing-nsfw/` (models, workflows, custom_nodes backup)
- **Source workflows**: D:\teasing-nsfw\workflows\ (локальные копии GUI JSON)
- **Inventory**: D:\teasing-nsfw\inventory\REPORT.md
- **Sister project (reels pipeline)**: [redsky-comfy-docker](https://github.com/aigirlsmarket-lang/redsky-comfy-docker)

## Custom nodes список

28 нод из его двух workflow'ов:

Animator stack:
- kijai/ComfyUI-WanVideoWrapper, kijai/ComfyUI-WanAnimatePreprocess, kijai/ComfyUI-KJNodes, kijai/ComfyUI-segment-anything-2

Xmode stack:
- ZhiHui6/zhihui_nodes_comfyui, Azornes/Comfyui-Resolution-Master, EllangoK/ComfyUI-post-processing-nodes, TheLustriVA/ComfyUI-Image-Size-Tools

Обе:
- ltdrdata/ComfyUI-Impact-Pack, ltdrdata/ComfyUI-Impact-Subpack, ltdrdata/ComfyUI-Manager, ClownsharkBatwing/RES4LYF, Fannovel16/comfyui_controlnet_aux, ainvfx/ComfyUI-SeedVR2_VideoUpscaler, PozzettiAndrea/ComfyUI-SAM3

UI / utility:
- yolain/ComfyUI-Easy-Use, pythongosssss/ComfyUI-Custom-Scripts, Kosinkadink/ComfyUI-VideoHelperSuite, cubiq/ComfyUI_essentials, chflame163/ComfyUI_LayerStyle, rgthree/rgthree-comfy, chrisgoringe/cg-use-everywhere, Smirnov75/ComfyUI-mxToolkit, crystian/ComfyUI-Crystools

Teskor utils:
- teskor-hub/comfyui-teskors-utils

Post / optional (но в его workflow'ах присутствуют):
- PGCRT/CRT-Nodes, fq393/ComfyUI-ZMG-Nodes, jnxmx/ComfyUI_HuggingFace_Downloader
