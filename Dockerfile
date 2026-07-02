# 通用「网页转图」Agent 环境 + Claude Code CLI
# ---------------------------------------------------------------------------
# 设计目标（参考 ../../CoinSummer/cs-agent-docker 的 agentbox 思路）：
#   通用环境，支持多种「写网页 → 截图成图片」的 skill（ljg-card、
#   guizang-social-card-skill 等同类卡片 / PPT / 信息图 skill）。
#   镜像只提供「环境」，不打包 skill 本身；skill 运行时挂载进来：
#       docker run -it --rm \
#         -v ~/.agents/skills:/root/.agents/skills \
#         -v ~/.claude:/root/.claude \
#         -v ~/Downloads:/root/Downloads \
#         coinsummerio/agentbox-web2img:latest
#
# 这类 skill 的共同原理：写一个 HTML（含 CJK 字体 / Google Fonts / CDN 图标动效），
# 再用无头 Chromium 截图成 PNG。因此通用依赖：
#   - Node.js（运行 capture/render/validate 等脚本）
#   - 单个全局 Playwright + Chromium（把 HTML 截图成图片）
#   - 宽字体覆盖：中日韩 / emoji（防豆腐块）+ Liberation/DejaVu（Arial/Times/Helvetica 替身）
#     + 模板用到的 Google/Web 字体全量烤入（DM Serif/Sans、Playfair、Inter、Caveat 等），
#       离线也能按设计渲染，不必空等 @import 外网。
#   - 运行时网络：模板仍可能从 CDN 加载 Lucide / Motion One 图标动效；字体已本地化，可离线渲染。
#   - claude 命令行（Claude Code CLI），在容器内直接驱动 skill
#
# 体积取舍：不用官方 Playwright 镜像（捆了 Chromium+Firefox+WebKit，~2.2GB），
# 改用精简 Node 基础镜像 + 只装一个最新 Chromium，约 ~1.1GB。
# 全局只装一个 playwright 版本：所有 skill 统一走它（Playwright API 跨小版本兼容）。
# 注意：如果挂载进来的 skill 自带了 node_modules/playwright，Node 会优先用它本地的，
#       可能找不到匹配的浏览器 —— 让 skill 不带自带依赖、统一用全局这一个版本即可。
# ---------------------------------------------------------------------------
FROM node:24-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.126
# 全局 playwright 版本（所有 skill 共用这一个）；要升级直接 bump
ARG PLAYWRIGHT_VERSION=1.60.0

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/root/.local/bin:$PATH \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    # 让运行时挂载、没有自带 node_modules 的 skill 也能 require('playwright')
    NODE_PATH=/usr/local/lib/node_modules

# 字体兜底 + 常用工具（对齐 cs-agent-docker base 的基础工具集）
#   fonts-noto-cjk*       : 中日韩兜底，防豆腐块
#   fonts-liberation2/dejavu : Arial/Times/Helvetica 替身（guizang 瑞士风用到 Helvetica）
#   xz-utils / pngquant   : 解压 .tar.xz、压缩 PNG（都是实测里"想用却没有"的）
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        bash \
        jq \
        ripgrep \
        tree \
        xz-utils \
        pngquant \
        fonts-noto-cjk \
        fonts-noto-cjk-extra \
        fonts-noto-color-emoji \
        fonts-liberation2 \
        fonts-dejavu-core \
        fontconfig \
    && rm -rf /var/lib/apt/lists/*

# 全量烤入模板用到的 Google/Web 字体，保证离线也能按设计渲染，并避免 capture.js
# 的 networkidle 一直等外网。用稀疏 + 部分克隆只拉需要的字族（只下 TTF，几十 MB）。
#   ljg-card    : DM Sans / DM Serif Display / Caveat / JetBrains Mono / Kalam /
#                 Permanent Marker / Ma Shan Zheng / ZCOOL QingKe HuangYou
#   guizang     : Playfair Display / Inter
# Permanent Marker 是 Apache 许可（在 apache/ 目录），其余在 ofl/；两处都列，缺的自动忽略。
RUN set -eux; \
    git clone --filter=blob:none --no-checkout --depth 1 \
        https://github.com/google/fonts.git /tmp/gfonts; \
    cd /tmp/gfonts; \
    git sparse-checkout init --cone; \
    git sparse-checkout set \
        ofl/dmsans ofl/dmserifdisplay ofl/playfairdisplay ofl/inter \
        ofl/caveat ofl/jetbrainsmono ofl/kalam ofl/mashanzheng \
        ofl/zcoolqingkehuangyou ofl/permanentmarker apache/permanentmarker; \
    git checkout; \
    mkdir -p /usr/share/fonts/truetype/google; \
    find . -name '*.ttf' -exec cp -f {} /usr/share/fonts/truetype/google/ \; ; \
    cd /; rm -rf /tmp/gfonts

# KingHwa_OldSong（京華老宋体）非 Google Fonts，需自备直链才装（默认跳过、不影响构建）。
#   docker build --build-arg KINGHWA_TTF_URL=<ttf 直链> ...
ARG KINGHWA_TTF_URL=""
RUN if [ -n "${KINGHWA_TTF_URL}" ]; then \
        curl -fsSL "${KINGHWA_TTF_URL}" -o /usr/share/fonts/truetype/google/KingHwa_OldSong.ttf \
        || echo "KingHwa 字体下载失败，跳过"; \
    fi

# fontconfig 别名：模板里的 Google CJK 家族名映射到镜像已装的 Noto CJK，避免同名不匹配
RUN mkdir -p /etc/fonts/conf.d \
    && printf '%s\n' \
    '<?xml version="1.0"?>' \
    '<!DOCTYPE fontconfig SYSTEM "fonts.dtd">' \
    '<fontconfig>' \
    '  <match target="pattern"><test name="family"><string>Noto Serif SC</string></test>' \
    '    <edit name="family" mode="prepend" binding="strong"><string>Noto Serif CJK SC</string></edit></match>' \
    '  <match target="pattern"><test name="family"><string>Noto Sans SC</string></test>' \
    '    <edit name="family" mode="prepend" binding="strong"><string>Noto Sans CJK SC</string></edit></match>' \
    '  <match target="pattern"><test name="family"><string>PingFang SC</string></test>' \
    '    <edit name="family" mode="prepend" binding="strong"><string>Noto Sans CJK SC</string></edit></match>' \
    '</fontconfig>' \
    > /etc/fonts/conf.d/09-web-cjk-aliases.conf \
    && fc-cache -f

# Claude Code CLI —— 官方安装脚本，原生二进制，版本可固定（同 cs-agent-docker base）
RUN curl --connect-timeout 15 --max-time 180 --retry 5 --retry-all-errors --retry-delay 3 \
        -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && bash /tmp/claude-install.sh "${CLAUDE_CODE_VERSION}" \
    && rm -f /tmp/claude-install.sh \
    && ln -sf /root/.local/bin/claude /usr/local/bin/claude

# 全局装一个 playwright，并只装 Chromium（--with-deps 自动装 Chromium 的系统库）
RUN npm install -g "playwright@${PLAYWRIGHT_VERSION}" \
    && npx playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/*

# 渲染产物默认写到 ~/Downloads/
RUN mkdir -p /root/Downloads

RUN claude --version && node --version && npx playwright --version

WORKDIR /workspace
CMD ["bash"]
