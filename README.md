# 智谱 GLM Coding Plan 助手 + 本地自动验证码

油猴脚本 + 本地 CPU/GPU OCR 后端，用于 GLM Coding Plan 页面流程辅助和中文点选验证码自动识别。

默认使用作者内置折扣入口，可获得 95 折优惠；介意者可在脚本中自行替换入口参数。

## 演示

https://github.com/user-attachments/assets/e1a56d07-5c4d-4aa1-a567-909dd25bd037

## 能做什么

- 自动跳回限流页，减少手动刷新和返回操作
- 提前解除页面按钮不可点击状态，让订阅按钮可以操作
- 自动切换套餐和订阅周期，按配置顺序尝试
- 遇到中文点选验证码时，调用本地 OCR 后端自动识别并点击
- 支持 CPU/GPU 本地识别，不上传验证码图片到第三方服务
- 支持一键多开窗口，方便补货前预热和同时监控
- 默认不自动关闭无效支付链接/限流弹窗，需要在配置面板里手动开启
- 默认使用作者内置折扣入口进入 GLM Coding Plan

后端的安装、GPU/CPU 自动选择、worker 数、OCR 配置等说明见：

```text
docs/backend_config.md
```

## 快速开始

### 1. 安装后端

如果你没有 Python，直接运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap_windows.ps1 -Target auto
```

如果已经有 Python，也可以运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup_backend.ps1 -Target auto
```

### 2. 启动后端

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start_backend.ps1 -Mode auto
```

启动后可检查：

```powershell
Invoke-RestMethod http://127.0.0.1:8888/health
```

### 3. 安装油猴脚本

1. 安装 Tampermonkey https://www.tampermonkey.net。
2. 打开仓库根目录的 `glm-coding-helper.user.js`。
3. 复制全部内容，新建 Tampermonkey 脚本并保存。
4. 打开 GLM Coding Plan 页面。

仓库根目录的 `glm-coding-helper.user.js` 是给普通用户安装的入口；`scripts/userscripts/` 只是保留给开发和旧路径兼容。

脚本默认连接本地后端：

```text
http://127.0.0.1:8888
```

### 快捷键

- `Esc`：关闭系统繁忙弹窗或支付弹窗
- `Enter` / `Space`：点击验证码确认按钮

油猴菜单里可以打开配置面板、一键多开窗口、清除今日套餐状态缓存。

## 常用启动方式

强制 GPU：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start_backend.ps1 -Mode gpu
```

强制 CPU：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start_backend.ps1 -Mode cpu
```

指定 CPU worker：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start_backend.ps1 -Mode cpu -CpuWorkers 3
```

## 模型文件

默认检测权重路径：

```text
models/weights/yolo-captcha-detector.pt
```

也可以用环境变量覆盖：

```powershell
$env:CNCAPTCHA_DETECTOR_PATH="D:\path\to\best.pt"
```

## 致谢

本项目的油猴前端脚本是在 Greasy Fork 用户 `mumumi` 的《GLM Coding Plan抢购助手》基础上二次开发而来：

https://greasyfork.org/zh-CN/scripts/572157-glm-coding-plan%E6%8A%A2%E8%B4%AD%E5%8A%A9%E6%89%8B

感谢原作者长期维护和分享。原脚本采用 GNU GPLv3 许可证；本仓库继续保留相同许可证声明，并在其基础上增加本地 CPU/GPU OCR 后端、自动验证码识别和开源部署脚本。

## 许可证

本项目基于 GNU GPLv3 发布。油猴脚本基于 Greasy Fork 用户 `mumumi` 的 GPLv3 脚本二次开发，继续保留相同许可证。

## 说明

本项目用于本地 OCR、自动化辅助和技术研究。请遵守目标网站服务条款和当地法律法规，自行承担使用风险。
