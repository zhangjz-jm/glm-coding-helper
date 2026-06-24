#!/bin/bash
# GLM Coding Helper 一键启动（Linux）
# 用途：首次安装 CPU/GPU 后端环境并启动 pipeline 后端（headless）。
#
# 命令行运行：./one-click-start.sh
#
# Linux 说明：默认 auto 模式会优先尝试 NVIDIA GPU；GPU 环境不可用时回退 CPU。
#            如果系统中存在 uv，会优先用 uv 管理 Python 3.12、venv 和依赖安装。
#            未传 --pip-arg 时，会自动探测可用 PyPI 镜像（国内优先）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

# ── 解析参数 ───────────────────────────────────────────────────
TARGET="auto"
PORT="${CNCAPTCHA_PORT:-8888}"
PIP_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            shift
            if [ $# -eq 0 ]; then
                echo "[错误] --target 需要跟一个参数：auto/cpu/gpu" >&2
                exit 1
            fi
            TARGET="$1"
            shift
            ;;
        --port)
            shift
            if [ $# -eq 0 ]; then
                echo "[错误] --port 需要跟一个端口号" >&2
                exit 1
            fi
            PORT="$1"
            shift
            ;;
        --pip-arg)
            shift
            if [ $# -eq 0 ]; then
                echo "[错误] --pip-arg 需要跟一个参数" >&2
                exit 1
            fi
            PIP_ARGS+=("$1")
            shift
            ;;
        --help|-h)
            sed -n '2,8p' "$0"
            exit 0
            ;;
        *)
            echo "[错误] 未知参数：$1" >&2
            exit 1
            ;;
    esac
done

case "$TARGET" in
    auto|cpu|gpu) ;;
    *)
        echo "[错误] --target 仅支持 auto/cpu/gpu，当前为：$TARGET" >&2
        exit 1
        ;;
esac

cat <<'EOF'
------------------------------------------------------------
 GLM Coding Helper 一键启动（Linux）
------------------------------------------------------------
 首次运行会自动创建 .venv_paddle / .venv_paddle_gpu 并安装依赖。
 安装包较大（paddle / ultralytics），请保持网络畅通。
 如果系统中存在 uv，将优先使用 uv 管理 Python 3.12、venv 和依赖。
------------------------------------------------------------

EOF

# ── 1. 检查系统和 Release 文件 ────────────────────────────────
if [ "$(uname -s)" != "Linux" ]; then
    echo "[错误] 此脚本仅支持 Linux。" >&2
    pause_if_tty "按回车键退出..."
    exit 1
fi

# ── 辅助函数 ───────────────────────────────────────────────────
pause_if_tty() {
    local prompt="${1:-按回车键退出...}"
    if [ -t 0 ]; then
        read -r -p "$prompt"
    fi
}

has_nvidia_gpu() {
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

test_python_imports() {
    local py="$1"
    local code="$2"
    [ -x "$py" ] || return 1
    "$py" -c "$code" >/dev/null 2>&1
}

test_foreign_venv() {
    local venv_dir="$1"
    local cfg="$venv_dir/pyvenv.cfg"

    [ -d "$venv_dir" ] || return 1
    [ -f "$cfg" ] || return 0

    local executable
    executable="$(sed -n 's/^executable[[:space:]]*=[[:space:]]*//p' "$cfg" | head -n1 || true)"
    if [ -n "$executable" ] && [ ! -x "$executable" ]; then
        return 0
    fi

    local created_at
    created_at="$(sed -n 's/^command[[:space:]]*=.* -m venv //p' "$cfg" | head -n1 | sed 's/^"//; s/"$//' || true)"
    if [ -n "$created_at" ]; then
        local expected actual
        expected="$(cd "$venv_dir" && pwd -P)"
        if [ -d "$created_at" ]; then
            actual="$(cd "$created_at" && pwd -P)"
            [ "$actual" = "$expected" ] || return 0
        fi
    fi

    return 1
}

# shellcheck source=scripts/pypi_mirror.sh
source "$SCRIPT_DIR/scripts/pypi_mirror.sh"

assert_required_files() {
    local missing=()
    local required=(
        "scripts/setup_backend_linux.sh"
        "scripts/tools/start_backend.py"
        "requirements-backend-cpu.txt"
        "requirements-backend-gpu.txt"
    )

    for rel in "${required[@]}"; do
        if [ ! -f "$SCRIPT_DIR/$rel" ]; then
            missing+=("$rel")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "[FAIL] Release package is incomplete. Missing files:" >&2
        for item in "${missing[@]}"; do
            echo "       - $item" >&2
        done
        echo "Please re-extract the full latest release zip and retry." >&2
        pause_if_tty "Press Enter to exit"
        exit 1
    fi
}

invoke_setup() {
    local setup_target="$1"
    local venv_py="$2"
    local force_recreate="${3:-0}"
    local setup_script="$SCRIPT_DIR/scripts/setup_backend_linux.sh"
    local -a setup_args=("--target" "$setup_target")

    # 与 Windows Invoke-Bootstrap 一致：外来/损坏 venv，或目标 python 已存在时先删再建。
    if [ "$force_recreate" -eq 1 ] || { [ -n "$venv_py" ] && [ -e "$venv_py" ]; }; then
        echo "Existing backend environment failed portability/import checks. Recreating it..."
        setup_args+=("--recreate")
    fi

    for arg in "${PIP_ARGS[@]}"; do
        setup_args+=("--pip-arg" "$arg")
    done

    mkdir -p "$SCRIPT_DIR/logs"
    echo "详细安装日志: $SCRIPT_DIR/logs/backend-install.log"
    bash "$setup_script" "${setup_args[@]}" 2>&1 | tee "$SCRIPT_DIR/logs/backend-install.log"
}

assert_required_files

# ── 2. 选择安装目标和虚拟环境 ──────────────────────────────────
INSTALL_TARGET="$TARGET"
if [ "$INSTALL_TARGET" = "auto" ]; then
    if has_nvidia_gpu; then
        INSTALL_TARGET="gpu"
    else
        INSTALL_TARGET="cpu"
    fi
fi

CPU_VENV="$SCRIPT_DIR/.venv_paddle"
GPU_VENV="$SCRIPT_DIR/.venv_paddle_gpu"
CPU_PY="$CPU_VENV/bin/python"
GPU_PY="$GPU_VENV/bin/python"
IMPORT_CODE="import fastapi, uvicorn, psutil, ultralytics, paddleocr, paddlex, paddle, cv2, PIL, numpy"

if [ "$INSTALL_TARGET" = "gpu" ]; then
    SELECTED_VENV="$GPU_VENV"
    SELECTED_PY="$GPU_PY"
else
    SELECTED_VENV="$CPU_VENV"
    SELECTED_PY="$CPU_PY"
fi

# ── 3. 安装或修复虚拟环境 ──────────────────────────────────────
NEEDS_RECREATE=0
if test_foreign_venv "$SELECTED_VENV"; then
    NEEDS_RECREATE=1
    echo "[WARN] Existing backend environment was created on another machine or in another folder. It will be rebuilt locally." >&2
fi

READY=0
if [ "$NEEDS_RECREATE" -eq 0 ] && test_python_imports "$SELECTED_PY" "$IMPORT_CODE"; then
    READY=1
fi

if [ "$READY" -eq 0 ]; then
    echo "Backend environment is missing or incomplete. Installing $INSTALL_TARGET environment..."
    ensure_pypi_mirror_pip_args
    if ! invoke_setup "$INSTALL_TARGET" "$SELECTED_PY" "$NEEDS_RECREATE"; then
        SETUP_EXIT=1
    else
        SETUP_EXIT=0
    fi

    READY=0
    if test_python_imports "$SELECTED_PY" "$IMPORT_CODE"; then
        READY=1
    fi

    if [ "$SETUP_EXIT" -ne 0 ] || [ "$READY" -eq 0 ]; then
        if [ "$TARGET" = "auto" ] && [ "$INSTALL_TARGET" = "gpu" ]; then
            echo "[WARN] GPU bootstrap failed or remained incomplete. Falling back to CPU environment..." >&2
            INSTALL_TARGET="cpu"
            SELECTED_VENV="$CPU_VENV"
            SELECTED_PY="$CPU_PY"
            if ! invoke_setup "cpu" "$CPU_PY" 0; then
                SETUP_EXIT=1
            else
                SETUP_EXIT=0
            fi
            READY=0
            if test_python_imports "$SELECTED_PY" "$IMPORT_CODE"; then
                READY=1
            fi
        fi
    fi

    if [ "$READY" -eq 0 ]; then
        echo "[FAIL] Backend environment repair failed. Required deps still missing." >&2
        if [ "$TARGET" = "auto" ]; then
            echo "       Auto mode already attempted GPU/CPU fallback." >&2
        fi
        echo "       完整安装日志已保存到 logs/backend-install.log，排查请提供此文件。" >&2
        pause_if_tty "按回车键退出..."
        exit 1
    fi
fi

# ── 4. 安装 CPU fallback 环境 ──────────────────────────────────
if [ "$TARGET" = "auto" ] && [ "$INSTALL_TARGET" = "gpu" ] && ! test_python_imports "$CPU_PY" "$IMPORT_CODE"; then
    echo "CPU fallback environment is missing. Installing CPU environment for auto fallback..."
    if ! invoke_setup "cpu" "$CPU_PY" 0; then
        echo "[WARN] CPU fallback environment installation failed. Auto mode will still try GPU first." >&2
    fi
fi

# ── 5. 检查 YOLO 权重 ──────────────────────────────────────────
WEIGHT="$SCRIPT_DIR/models/weights/yolo-captcha-detector.pt"
if [ ! -f "$WEIGHT" ]; then
    echo "[错误] 缺少检测权重：$WEIGHT" >&2
    echo "       请从 Release 包补齐 models/weights/yolo-captcha-detector.pt 后再启动。" >&2
    pause_if_tty "按回车键退出..."
    exit 1
fi

export CNCAPTCHA_PORT="$PORT"
export CNCAPTCHA_CPU_OCR_PYTHON="$CPU_PY"
export CNCAPTCHA_GPU_OCR_PYTHON="$GPU_PY"

# ── 6. 启动后端（headless）────────────────────────────────────
START_MODE="$INSTALL_TARGET"
if [ "$TARGET" = "auto" ]; then
    START_MODE="auto"
fi

echo ""
echo "[INFO] 使用 Python：$SELECTED_PY"
echo "[INFO] 启动后端：http://127.0.0.1:$PORT （Ctrl+C 停止）"
echo ""
exec "$SELECTED_PY" "$SCRIPT_DIR/scripts/tools/start_backend.py" --headless --mode "$START_MODE" --port "$PORT"
