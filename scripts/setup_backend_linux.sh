#!/bin/bash
# GLM Coding Helper 后端环境搭建（Linux）
#
# 等价于 Windows 的 setup_backend.ps1 / setup_backend.py：
#   1. 检测 Linux、NVIDIA GPU 和 Python 3.12
#   2. 优先使用 uv 创建 .venv_paddle / .venv_paddle_gpu
#   3. pip install -r requirements-backend-*.txt
#   4. smoke test 核心依赖
#   5. 检查 YOLO 权重
#
# 用法：
#   ./scripts/setup_backend_linux.sh                      # 自动选择 GPU/CPU 环境
#   ./scripts/setup_backend_linux.sh --target cpu         # 安装 CPU 环境
#   ./scripts/setup_backend_linux.sh --target gpu         # 安装 GPU 环境
#   ./scripts/setup_backend_linux.sh --target both        # 同时安装 CPU/GPU 环境
#   ./scripts/setup_backend_linux.sh --recreate           # 删除并重建选中环境
#   ./scripts/setup_backend_linux.sh --skip-install       # 只创建 venv，不安装依赖
#   ./scripts/setup_backend_linux.sh --no-smoke-test      # 跳过导入冒烟测试
#   ./scripts/setup_backend_linux.sh --pip-arg -i --pip-arg https://pypi.tuna.tsinghua.edu.cn/simple
#
# 未传 --pip-arg 时，会自动探测可用 PyPI 镜像（国内优先，与 Windows one-click 一致）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

# ── 解析参数 ───────────────────────────────────────────────────
TARGET="auto"
RECREATE=0
SKIP_INSTALL=0
NO_SMOKE_TEST=0
PIP_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            shift
            if [ $# -eq 0 ]; then
                echo "[错误] --target 需要跟一个参数：auto/cpu/gpu/both" >&2
                exit 1
            fi
            TARGET="$1"
            shift
            ;;
        --recreate)
            RECREATE=1
            shift
            ;;
        --skip-install)
            SKIP_INSTALL=1
            shift
            ;;
        --no-smoke-test)
            NO_SMOKE_TEST=1
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
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "[错误] 未知参数：$1" >&2
            exit 1
            ;;
    esac
done

case "$TARGET" in
    auto|cpu|gpu|both) ;;
    *)
        echo "[错误] --target 仅支持 auto/cpu/gpu/both，当前为：$TARGET" >&2
        exit 1
        ;;
esac

echo "GLM Coding Helper 后端环境搭建（Linux）"
echo "仓库根目录：$ROOT"
echo ""

# ── 1. 检查系统并选择 Python 3.12 ─────────────────────────────
if [ "$(uname -s)" != "Linux" ]; then
    echo "[错误] 此脚本仅支持 Linux。" >&2
    exit 1
fi

# shellcheck source=scripts/pypi_mirror.sh
source "$SCRIPT_DIR/pypi_mirror.sh"

has_uv() {
    command -v uv >/dev/null 2>&1
}

has_nvidia_gpu() {
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

resolve_python_312() {
    if [ -n "${CNCAPTCHA_PYTHON:-}" ]; then
        if [ ! -x "$CNCAPTCHA_PYTHON" ] && ! command -v "$CNCAPTCHA_PYTHON" >/dev/null 2>&1; then
            echo "[错误] CNCAPTCHA_PYTHON 指定的解释器不可用：$CNCAPTCHA_PYTHON" >&2
            exit 1
        fi
        echo "$CNCAPTCHA_PYTHON"
        return
    fi

    if has_uv; then
        if ! uv python find 3.12 >/dev/null 2>&1; then
            echo "[INFO] uv 可用，但未找到 Python 3.12；开始执行 uv python install 3.12" >&2
            uv python install 3.12 >&2
        fi
        uv python find 3.12
        return
    fi

    if command -v python3.12 >/dev/null 2>&1; then
        command -v python3.12
        return
    fi

    echo "[错误] 没有找到 Python 3.12。请先安装 Python 3.12，或安装 uv 后重试：" >&2
    echo "       curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
    echo "       uv python install 3.12" >&2
    exit 1
}

PY="$(resolve_python_312)"
PY_VERSION="$("$PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
if [ "$PY_VERSION" != "3.12" ]; then
    echo "[错误] 需要 Python 3.12，当前解释器版本为 ${PY_VERSION:-未知}：$PY" >&2
    echo "       可设置 CNCAPTCHA_PYTHON=/path/to/python3.12 后重试。" >&2
    exit 1
fi

if has_uv; then
    echo "[INFO] 使用 uv 管理虚拟环境和依赖"
fi
echo "[INFO] 使用 Python：$PY ($PY_VERSION)"

# ── 2. 选择安装目标 ─────────────────────────────────────────────
if [ "$TARGET" = "auto" ]; then
    if has_nvidia_gpu; then
        TARGET="gpu"
    else
        TARGET="cpu"
    fi
    echo "[INFO] 自动选择安装目标：$TARGET"
fi

if [ "$TARGET" = "both" ]; then
    SELECTED=("cpu" "gpu")
else
    SELECTED=("$TARGET")
fi

venv_python() {
    echo "$1/bin/python"
}

# ── 3. 创建 / 重建 venv ────────────────────────────────────────
create_venv() {
    local venv_dir="$1"
    local venv_py
    venv_py="$(venv_python "$venv_dir")"

    if [ "$RECREATE" -eq 1 ] && [ -d "$venv_dir" ]; then
        echo "[INFO] 删除已有环境：$venv_dir"
        rm -rf "$venv_dir"
    fi

    if [ ! -x "$venv_py" ]; then
        echo "[INFO] 创建虚拟环境：$venv_dir"
        if has_uv; then
            uv venv --python "$PY" "$venv_dir"
        else
            "$PY" -m venv "$venv_dir"
        fi
    fi
}

# ── 4. 安装依赖 ────────────────────────────────────────────────
install_with_pip() {
    local venv_py="$1"
    local req="$2"

    if [ ! -f "$req" ]; then
        echo "[错误] 缺少 $req，请确认是完整的 Release 包。" >&2
        exit 1
    fi

    echo "[INFO] 升级 pip / setuptools / wheel"
    if has_uv; then
        uv pip install --python "$venv_py" --upgrade pip setuptools wheel "${PIP_ARGS[@]}"
    else
        "$venv_py" -m pip install --upgrade pip setuptools wheel "${PIP_ARGS[@]}"
    fi

    echo "[INFO] 安装依赖：$req（可能需要几分钟）..."
    if has_uv; then
        uv pip install --python "$venv_py" -r "$req" "${PIP_ARGS[@]}"
    else
        "$venv_py" -m pip install -r "$req" "${PIP_ARGS[@]}"
    fi
}

# ── 5. smoke test ─────────────────────────────────────────────
smoke_test() {
    local venv_py="$1"
    local mode="$2"

    echo ""
    echo "[INFO] 运行 ${mode^^} 导入冒烟测试..."
    "$venv_py" -c "import PIL, cv2, numpy, ultralytics; from paddleocr import TextRecognition; print('core imports ok')"
    "$venv_py" -c "import fastapi, uvicorn, psutil; print('backend deps ok')"

    if [ "$mode" = "gpu" ]; then
        "$venv_py" -c "import paddle; print('cuda_compiled=', paddle.is_compiled_with_cuda()); print('cuda_count=', paddle.device.cuda.device_count() if paddle.is_compiled_with_cuda() else 0)"
    fi
}

if [ "$SKIP_INSTALL" -eq 0 ]; then
    ensure_pypi_mirror_pip_args
fi

for mode in "${SELECTED[@]}"; do
    if [ "$mode" = "gpu" ]; then
        VENV_DIR="$ROOT/.venv_paddle_gpu"
        REQ="$ROOT/requirements-backend-gpu.txt"
    else
        VENV_DIR="$ROOT/.venv_paddle"
        REQ="$ROOT/requirements-backend-cpu.txt"
    fi
    VENV_PY="$(venv_python "$VENV_DIR")"

    echo ""
    echo "=== Setting up ${mode^^} backend environment ==="
    create_venv "$VENV_DIR"

    if [ "$SKIP_INSTALL" -eq 0 ]; then
        install_with_pip "$VENV_PY" "$REQ"
    fi

    if [ "$NO_SMOKE_TEST" -eq 0 ]; then
        smoke_test "$VENV_PY" "$mode"
    fi
done

# ── 6. 检查 YOLO 权重 ──────────────────────────────────────────
WEIGHT="$ROOT/models/weights/yolo-captcha-detector.pt"
echo ""
if [ -f "$WEIGHT" ]; then
    echo "[OK] 检测权重就绪：$WEIGHT"
else
    echo "[WARN] 缺少检测权重：$WEIGHT" >&2
    echo "       请从 Release 包补齐该文件后再启动后端。" >&2
fi

# ── 7. 完成 ────────────────────────────────────────────────────
print_completion_hints() {
    local mode py has_cpu=0 has_gpu=0

    for mode in "${SELECTED[@]}"; do
        case "$mode" in
            cpu) has_cpu=1 ;;
            gpu) has_gpu=1 ;;
        esac
    done

    echo ""
    echo "完成。启动后端："
    echo ""

    for mode in "${SELECTED[@]}"; do
        if [ "$mode" = "gpu" ]; then
            py="$ROOT/.venv_paddle_gpu/bin/python"
        else
            py="$ROOT/.venv_paddle/bin/python"
        fi
        echo "  ${mode^^} 环境："
        echo "    GUI:      $py $ROOT/scripts/tools/start_backend.py --mode $mode"
        echo "    headless: $py $ROOT/scripts/tools/start_backend.py --headless --mode $mode"
        echo ""
    done

    if [ "$has_gpu" -eq 1 ] && [ "$has_cpu" -eq 1 ]; then
        echo "  auto 模式（GPU 优先，失败回退 CPU）："
        echo "    $ROOT/.venv_paddle_gpu/bin/python $ROOT/scripts/tools/start_backend.py --headless --mode auto"
        echo ""
    elif [ "$has_gpu" -eq 1 ]; then
        echo "  提示：使用 auto 模式前，建议再安装 CPU 回退环境："
        echo "    ./scripts/setup_backend_linux.sh --target cpu"
        echo ""
    fi

    echo "  Linux 支持 CPU；如 NVIDIA/CUDA/PaddlePaddle 环境可用，也支持 GPU/auto 模式。"
}

print_completion_hints
