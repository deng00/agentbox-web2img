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
#   - 运行时网络：模板常 @import fonts.googleapis.com，并从 CDN 加载 Lucide / Motion One；
#     本地 Noto CJK 仅作兜底，渲染时建议放行外网。
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
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        bash \
        jq \
        ripgrep \
        tree \
        fonts-noto-cjk \
        fonts-noto-cjk-extra \
        fonts-noto-color-emoji \
        fonts-liberation2 \
        fonts-dejavu-core \
        fontconfig \
    && fc-cache -f \
    && rm -rf /var/lib/apt/lists/*

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
