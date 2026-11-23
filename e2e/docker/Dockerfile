# Godot headless for the e2e checks: the standard and .NET editors of the lowest supported
# version, the Linux and web export templates, Chromium for the web export, and .NET 8.
FROM mcr.microsoft.com/dotnet/sdk:8.0
ARG GODOT=4.5.1
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip python3 fontconfig libfontconfig1 chromium \
    && rm -rf /var/lib/apt/lists/*
ENV DL="curl -fL --retry 8 --retry-all-errors --retry-delay 3 -sS"
RUN set -e; base=https://github.com/godotengine/godot/releases/download/${GODOT}-stable; \
    $DL -o /tmp/g.zip $base/Godot_v${GODOT}-stable_linux.x86_64.zip; \
    unzip -q /tmp/g.zip -d /opt/godot; ln -s /opt/godot/Godot_v${GODOT}-stable_linux.x86_64 /usr/local/bin/godot; rm /tmp/g.zip
RUN set -e; base=https://github.com/godotengine/godot/releases/download/${GODOT}-stable; \
    $DL -o /tmp/m.zip $base/Godot_v${GODOT}-stable_mono_linux_x86_64.zip; \
    unzip -q /tmp/m.zip -d /opt/godot-mono; \
    ln -s /opt/godot-mono/Godot_v${GODOT}-stable_mono_linux_x86_64/Godot_v${GODOT}-stable_mono_linux.x86_64 /usr/local/bin/godot-mono; \
    rm /tmp/m.zip
RUN set -e; base=https://github.com/godotengine/godot/releases/download/${GODOT}-stable; \
    dir=/root/.local/share/godot/export_templates/${GODOT}.stable; mkdir -p $dir; \
    for i in $(seq 1 30); do curl -fL -sS -C - -o /tmp/t.tpz $base/Godot_v${GODOT}-stable_export_templates.tpz && break; sleep 5; done; unzip -tq /tmp/t.tpz >/dev/null; \
    unzip -q -j /tmp/t.tpz templates/version.txt templates/linux_release.x86_64 templates/linux_debug.x86_64 \
      templates/web_nothreads_release.zip templates/web_nothreads_debug.zip -d $dir; \
    rm /tmp/t.tpz
# addr2line: Godot's crash handler runs it for each frame (without it the handler itself fails).
RUN apt-get update && apt-get install -y --no-install-recommends binutils && rm -rf /var/lib/apt/lists/*
ENV GODOT_SILENCE_ROOT_WARNING=1
WORKDIR /work
