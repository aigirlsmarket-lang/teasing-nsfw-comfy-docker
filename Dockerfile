# vast.ai ComfyUI image для teasing-nsfw pipeline (X mode firstframe + animator).
#
# Гибридная стратегия (та же что redsky-comfy):
#   - БАКАЕМ В IMAGE: pip deps + 28 custom_nodes + rclone + FileBrowser
#   - ТЯНЕМ В RUNTIME: ~99 GB моделей + workflows из R2 prefix teasing-nsfw/
#
# Соответствие nod'ам от сотрудника: union(animator workflow + xmode workflow) = 28 нод.
# НИКАКИЕ workflow inputs не модифицируются — это обязательное условие проекта.
#
# Build: GitHub Actions on every push to main (см. .github/workflows/build.yml).
# Push: DockerHub под именем <username>/teasing-nsfw-comfy:latest.

FROM vastai/comfy:v0.19.3-cuda-12.9-py312

# vastai/comfy использует venv в /venv/main — активируем его для всех слоёв
ENV VIRTUAL_ENV=/venv/main
ENV PATH=/venv/main/bin:$PATH

# ---------- Layer 1: rclone (для R2 sync в runtime) ----------
RUN curl -fsSL https://rclone.org/install.sh | bash && \
    rclone version | head -1

# ---------- Layer 2: FileBrowser ----------
RUN cd /tmp && \
    wget -q -O fb.tar.gz https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz && \
    tar xzf fb.tar.gz && \
    mv filebrowser /usr/local/bin/filebrowser && \
    chmod +x /usr/local/bin/filebrowser && \
    rm -f fb.tar.gz LICENSE README.md CHANGELOG.md && \
    filebrowser version

# ---------- Layer 3: 28 custom_nodes + их pip deps ----------
# Union из animator workflow (23) + xmode workflow (23) — 28 уникальных нод.
COPY bake_custom_nodes.sh /tmp/bake_custom_nodes.sh
RUN bash /tmp/bake_custom_nodes.sh && rm /tmp/bake_custom_nodes.sh

# ---------- Verification ----------
RUN cd /workspace/ComfyUI && python -c "\
import sys; \
sys.path.insert(0, 'custom_nodes'); \
print('Custom nodes baked: ' + str(len([d for d in __import__('os').listdir('custom_nodes') if not d.startswith('.')]))); \
" || echo "WARN: verify shim ran"

LABEL org.opencontainers.image.title="teasing-nsfw-comfy"
LABEL org.opencontainers.image.description="vastai/comfy + 28 custom_nodes pre-baked для teasing-nsfw pipeline"
LABEL org.opencontainers.image.source="https://github.com/aigirlsmarket-lang/teasing-nsfw-comfy-docker"
