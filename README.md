# FrameFlow · 视频转 GIF

SwiftUI 视频转 GIF 工具。拖入视频后调整画质、倍速和大小上限，转换结果保存到原视频目录。

## 功能

- FFmpeg 调色板采样与 GIF 编码
- 多任务队列和并行分段编码
- Gifsicle 合并与异常格式回退

## 从源码构建

要求 macOS 14 或更新版本，以及 Xcode Command Line Tools。

```bash
./build.sh --compile-only
```

这会编译 Swift 程序到 `build/`。运行完整应用还需要以下依赖：

FFmpeg、ffprobe、Gifsicle；放在 `Resources/Tools/`。使用动态链接版本时，还需将依赖库放在应用的 `Contents/Frameworks/`。

`Sources/` 存放原生界面源码，`Resources/` 存放应用资源和后端脚本。准备好依赖后运行 `./build.sh` 生成应用包。构建脚本执行本地 ad-hoc 签名；正式发布需另行签名和公证。

如已有对应应用的完整依赖，可以指定其资源目录重新打包：

```bash
APP_RESOURCES="/path/to/Application.app/Contents/Resources" ./build.sh
```

此方式复用第三方运行时，重新编译本仓库的原生程序；构建结果在 `build/`，不提交到源码仓库。脚本不会打包已有的文件索引或用户转换结果。

## 许可证与第三方组件

本项目原创界面、脚本和构建文件使用 [MIT License](LICENSE)。第三方源码、图标和运行时遵循其原有许可，根目录许可不覆盖第三方材料。

[FFmpeg](https://github.com/FFmpeg/FFmpeg)、[Gifsicle](https://github.com/kohler/gifsicle)；许可证见 `licenses/`。
