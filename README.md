# agentbox-web2img

通用「网页转图」Agent 环境镜像。给「写网页 → 无头 Chromium 截图成 PNG」这类
skill（如 [ljg-card](https://github.com/lijigang/ljg-skills)、
[guizang-social-card-skill](https://github.com/op7418/guizang-social-card-skill)）
提供运行时,镜像**只提供环境,不打包 skill**,skill 在运行时挂载进来。

## 内容

- **Node.js 24**
- **Playwright + 单个 Chromium**(`--with-deps`,含全部系统库)
- **Claude Code CLI**(`claude`)
- 字体全量本地化:
  - Noto CJK / emoji + Liberation / DejaVu(Arial/Times/Helvetica 替身)
  - 模板用到的 Google/Web 字体烤入镜像(DM Serif Display / DM Sans / Playfair Display / Inter / Caveat / JetBrains Mono / Kalam / Permanent Marker / Ma Shan Zheng / ZCOOL QingKe HuangYou)
  - fontconfig 别名把 `Noto Serif/Sans SC`、`PingFang SC` 映射到已装的 Noto CJK
  - → **离线也能按设计渲染**,不必空等 `@import` 外网(消除 networkidle 超时)
- 常用工具:`git` `curl` `jq` `ripgrep` `tree` `xz-utils`
- PNG 压缩:`pngquant`(有损调色板,压得狠) + `optipng`(无损优化)
- 京華老宋体(KingHwa_OldSong)非 Google Fonts,默认不装;需要时构建传 `--build-arg KINGHWA_TTF_URL=<直链>`

## 使用

```bash
docker run -it --rm \
  -v ~/.agents/skills:/root/.agents/skills \
  -v ~/.claude:/root/.claude \
  -v ~/Downloads:/root/Downloads \
  deng00/agentbox-web2img:latest
```

- `claude` 运行时需要鉴权:挂载 `~/.claude`(登录态)或注入 `ANTHROPIC_API_KEY`。
- 模板常从 Google Fonts / CDN(Lucide、Motion One)加载资源,渲染时建议放行外网;本地 Noto CJK 仅作兜底。
- 挂载的 skill **不要带自带的 `node_modules/playwright`**,统一用容器内全局 playwright,避免浏览器版本不匹配。

## 发布

仅在 **main 分支上打 `v*` tag**(如 `v0.1.0`)时触发:GitHub Actions
(`.github/workflows/docker-publish.yml`)构建 `linux/amd64,arm64` 多架构镜像并推到 Docker Hub,
只发两个 tag —— 完整版本号(`0.1.0`)和 `latest`。

```bash
git tag v0.1.1 && git push origin v0.1.1
```

需要在仓库配置 Secret:`DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN`。
可选 Variable:`IMAGE_NAME`(默认 `<用户名>/agentbox-web2img`)、`CLAUDE_CODE_VERSION`。
