# Claude4RemoteDEV — 项目配置模板
# setup.sh 会据此在 <project>/.claude/c4rd/config.sh 生成实际配置。
# 所有路径用绝对路径。

# —— 远程服务器(执行 + 数据/模型/GPU 所在)——
REMOTE_ALIAS="c4rd-remote"                 # 给远程起的 ssh 别名(写入 ~/.ssh/config)
REMOTE_HOST="gpu.example.com"              # 远程地址(IP 或域名)
REMOTE_USER="ubuntu"                       # 远程用户名
REMOTE_PORT="22"                           # 远程 SSH 端口
REMOTE_ROOT="/home/ubuntu/myproject"       # 远程项目绝对路径(代码在这跑)
SSH_KEY="$HOME/.ssh/id_c4rd"               # 本机私钥路径

# —— 本机镜像(Claude 原生读写的代码副本)——
MIRROR_ROOT="$HOME/myproject"              # 本机镜像目录(通常就是你启动 claude 的项目目录)

# —— Mutagen 同步会话名(每项目唯一)——
SESSION="c4rd-myproject"

# —— 远程登录 shell 的 PATH 修复(让 uv/conda 等可见;不需要就设为 ':')——
# 常见:miniconda/uv/cargo 的 bin 目录不在非交互登录 shell 的 PATH 里。
REMOTE_PATH_FIX='export PATH="$HOME/miniconda3/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"'

# —— 远程不可达时的探活超时(秒)——
PROBE_TIMEOUT="3"
