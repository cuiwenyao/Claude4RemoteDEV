# remote-claude.md —— 用本地 Claude Code 远程驱动一台服务器做开发

一套通用方法:**Claude Code 跑在一台机器上,代码/数据/GPU 在另一台机器上**,做到「编辑原生、算力原生、文件实时双向同步」。与具体项目无关,换机器/换项目只改少量配置。

---

## 一、问题背景

典型三机拓扑(机器数可增减):

| 角色 | 说明 |
|---|---|
| **A** | 笔记本/入口终端,只做交互 |
| **B** | **能且只能在这里运行 Claude Code** 的机器(常因网络能访问 Anthropic API,或因权限只有它能装) |
| **C** | 目标服务器:代码、数据、模型、GPU 全在这,**不能安装 Claude Code** |

**核心矛盾**:Claude Code 的文件工具(Read/Edit/Write/Grep)只作用于**它自己所在机器的本地文件系统**,而代码必须在 C。所以要在 B 上「造出 C 的代码就在本地」,同时把执行转发到 C。

**为什么不用一些看似简单的做法**:
- ❌ **直接在 C 上跑 Claude**:本约束下 C 不能装。若你的约束其实是"网络"(只有 B 能连 API),更优解是"在 C 上跑 Claude,只把 API 流量经 B 代理出去",不需要本方案——先确认约束是权限还是网络。
- ❌ **SSHFS/NFS 把 C 挂到 B**:每次文件操作一次网络往返;跨境/高延迟链路上,Claude 频繁的小文件读写+grep 慢到不可用。
- ❌ **纯 SSH(`ssh C "cat/sed"` 读写)**:放弃 Claude 原生编辑工具,笨拙易错。

**本方案**:B 上放一份**代码镜像**(Claude 原生读写),用 **Mutagen 做实时双向同步**(任一边改动,另一边秒级可见),执行时把命令**转发**到 C。

> **一条不可逾越的物理约束**:大数据/模型/checkpoint(动辄数百 G)**不可能也不应该同步到 B**(B 通常是小盘 VPS,跨境也传不动)。所以**实时同步的对象是代码树**;大目录只留 C,按需 `cpull` 拉取结果。这不是工具限制,是物理限制。

---

## 二、解决方案(架构)

```
Claude(B) ─ 原生读写 → B 代码镜像 ⇄⇄ [Mutagen 实时双向同步] ⇄⇄ C 代码(权威副本)
                                                                    │ 原生运行(训练/GPU/git)
执行命令:c '<cmd>' ─ 先 mutagen flush(保证代码已到 C)─ ssh C 登录shell执行 ──┘
大文件(数据/模型/venv/日志/缓存):被忽略,永远只在 C
```

两个组件、各司其职:
- **文件层 = Mutagen**:实时、双向、增量、走 SSH,扛高延迟与断线自愈。只同步代码;大目录忽略。
- **执行层 = `c` helper**:`mutagen flush`(等最新改动同步到 C)→ 在 C 上登录 shell 执行。`flush` 保证永不跑旧代码。

产出:`~/.ssh/config` 一段、Mutagen 一条 sync 会话、两个 helper(`c`/`cpull`),外加一份大目录忽略清单。

---

## 三、前置条件

- **B**:`ssh`、`rsync`(cpull 用);能访问 GitHub 下载 Mutagen 二进制;有几十 MB~几 G 空闲盘放代码镜像。
- **C**:开着 sshd;账号能写 `~/.ssh/authorized_keys` 与家目录(Mutagen 会往 `~/.mutagen` 部署一个 agent)。
- **网络**:B 能 SSH 到 C。

---

## 四、部署步骤

> 占位符:`<REMOTE_USER>`=C 用户名 · `<REMOTE_HOST>`=C 地址 · `<PORT>`=SSH 端口 ·
> `<REMOTE_DIR>`=C 上项目绝对路径 · `<MIRROR>`=B 上镜像路径(如 `~/proj`) ·
> `<ALIAS>`=C 的 ssh 别名(如 `C`) · `<KEY>`=密钥路径 · `<NAME>`=同步会话名(如 `proj`)

### STEP 1 — 生成 SSH 密钥,公钥装到 C

```bash
# B 上(无口令,便于自动化/保活)
ssh-keygen -t rsa -b 4096 -f <KEY> -N "" -C "claude-remote"
cat <KEY>.pub
```
```bash
# C 上,追加公钥(别覆盖已有内容)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<粘贴公钥>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

### STEP 2 — B 配置 `~/.ssh/config`(连接复用,低延迟关键)

```
Host <ALIAS>
    HostName <REMOTE_HOST>
    Port <PORT>
    User <REMOTE_USER>
    IdentityFile <KEY>
    IdentitiesOnly yes
    ServerAliveInterval 20
    ServerAliveCountMax 3
    TCPKeepAlive yes
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 30m
```
```bash
chmod 600 ~/.ssh/config
ssh <ALIAS> 'echo OK; hostname'          # 测通(首次慢,建主连接)
for i in 1 2 3; do time ssh <ALIAS> true; done   # 热延迟 = 日常每命令开销
```
Mutagen 会复用系统 `ssh` 与本 config(别名、端口、密钥、连接复用全生效)。

### STEP 3 — 摸清 C 上项目(定忽略清单 + 环境)

```bash
ssh <ALIAS> '
  echo "== 顶层大小(找大目录) =="; du -sh <REMOTE_DIR>/* <REMOTE_DIR>/.[!.]* 2>/dev/null | sort -rh | head -30;
  echo "== 环境 =="; ls <REMOTE_DIR>/.venv <REMOTE_DIR>/pyproject.toml 2>/dev/null;
  echo "== 工具 PATH(登录shell) =="; for t in uv conda poetry; do echo -n "$t: "; bash -lc "command -v $t" 2>/dev/null || echo "不在登录shell PATH"; done
'
```
记下:**哪些目录大(要忽略)**、**环境管理器**、**工具是否在登录 shell PATH**(常见坑:`~/.bashrc` 对非交互 shell 直接 `return`,导致 uv/conda 不在 PATH → STEP 6 的 `c` 里显式补 PATH)。

### STEP 4 — 安装 Mutagen(B 上),起守护进程

```bash
ver=$(curl -sL https://api.github.com/repos/mutagen-io/mutagen/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
curl -sL -o /tmp/mutagen.tar.gz "https://github.com/mutagen-io/mutagen/releases/download/${ver}/mutagen_linux_amd64_${ver}.tar.gz"
sudo tar -xzf /tmp/mutagen.tar.gz -C /usr/local/bin    # 得到 mutagen 和 mutagen-agents.tar.gz
mutagen version && mutagen daemon start
```
> 非 root:解压到 `~/.local/bin`(确保在 PATH)。arm64 机器把 `amd64` 换成 `arm64`。

### STEP 5 — 建实时双向同步会话

先做一次初始镜像拉取(可选但推荐,减少首次协调量),再建 Mutagen 会话。忽略清单按 STEP 3 的大目录来:

```bash
mkdir -p <MIRROR>
# (可选)初始拉取代码,加速首次同步
rsync -az <ALIAS>:<REMOTE_DIR>/ <MIRROR>/ \
  --exclude='/data' --exclude='/.venv*' --exclude='/logs' --exclude='/.git' --exclude='/.tools'

mutagen sync create --name=<NAME> \
  --ignore-vcs --symlink-mode=ignore \
  --ignore='/data' --ignore='/datasets' \
  --ignore='/.venv' --ignore='/.venv*/' \
  --ignore='/logs' --ignore='/checkpoints' --ignore='/wandb' --ignore='/.tools' \
  --ignore='__pycache__' --ignore='*.pyc' \
  --ignore='*.pt' --ignore='*.ckpt' --ignore='*.safetensors' \
  --ignore='/CLAUDE.md' \
  <MIRROR>  <ALIAS>:<REMOTE_DIR>
mutagen sync list <NAME>        # 等到 Status: Watching for changes
```
要点:
- `--symlink-mode=ignore`:静默跳过软链(否则指向绝对路径的软链会刷大量 scan problems)。
- `--ignore-vcs`:忽略 `.git`(git 在 C 上跑,避免双向同步 .git 的冲突)。
- `--ignore='/CLAUDE.md'`:让本项目的桥接说明只留 B、不推到 C。
- 默认 **Two-Way-Safe** 模式:两边同时改同一文件会标记冲突而非静默覆盖,安全。

> **推荐:用 `.gitignore` 作为同步范围的唯一来源。** Mutagen 不会自动读 `.gitignore`(`--ignore-vcs`
> 只忽略 `.git` 目录),但两者都是 gitignore 风格语法,可 1:1 传递。做法:在项目根写好 `.gitignore`
> (大数据/模型/venv/日志/缓存等),再用下面的 `resync` 从它生成 `--ignore` 并重建会话;以后改了
> `.gitignore` 跑一次 `resync` 即可。这样 git 和同步范围永远一致,新增大目录只需在 `.gitignore` 里加一行。
>
> ```bash
> sudo tee /usr/local/bin/resync >/dev/null <<'SCRIPT'
> #!/bin/bash
> set -euo pipefail
> NAME="proj"; MIRROR="$HOME/proj"; REMOTE="C:/abs/path/on/C"; GI="$MIRROR/.gitignore"   # ← 改这三个
> mapfile -t pats < <(sed -E 's/\r$//' "$GI" | grep -vE '^[[:space:]]*(#|$)')
> args=(); for p in "${pats[@]}"; do args+=(--ignore="$p"); done
> mutagen sync terminate "$NAME" 2>/dev/null || true
> mutagen sync create --name="$NAME" --ignore-vcs --symlink-mode=ignore "${args[@]}" "$MIRROR" "$REMOTE"
> mutagen sync flush "$NAME" >/dev/null 2>&1 || true; mutagen sync list "$NAME" | grep -E 'Status|files'
> SCRIPT
> sudo chmod +x /usr/local/bin/resync && resync
> ```
> 注意:被 `.gitignore` 忽略的路径**不会同步到 C**。若某个只想「B 本地、不进仓库、也不同步」的文件
> (如本项目的 `CLAUDE.md`),把它也写进 `.gitignore` 即可。

### STEP 6 — 安装 helper:`c`(执行)、`cpull`(拉未同步的结果)

```bash
sudo tee /usr/local/bin/c >/dev/null <<'SCRIPT'
#!/bin/bash
# c '<命令>' —— 在远程 C 上执行。文件由 Mutagen 实时同步;执行前 flush,保证不跑旧代码。
set -euo pipefail
NAME="proj"                                  # ← 改成你的 mutagen 会话名 <NAME>
REMOTE_HOST="C"                              # ← ssh 别名 <ALIAS>
REMOTE_DIR="/abs/path/on/C"                  # ← <REMOTE_DIR>
PATH_FIX='export PATH="$HOME/miniconda3/bin:$HOME/.local/bin:$PATH"'   # ← 按 STEP3 调整,不需要就设为 ':'
mutagen sync flush "$NAME" >/dev/null 2>&1 || true
printf '%s\ncd %q || exit 1\n%s\n' "$PATH_FIX" "$REMOTE_DIR" "$*" | ssh "$REMOTE_HOST" bash -l -s
SCRIPT

sudo tee /usr/local/bin/cpull >/dev/null <<'SCRIPT'
#!/bin/bash
# cpull <相对路径> [...] —— 把远程"未同步"目录里的结果(日志/checkpoint)拉回镜像给 Claude 读。
set -euo pipefail
REMOTE_HOST="C"; REMOTE_DIR="/abs/path/on/C"; MIRROR="$HOME/proj"   # ← 改成你的值
for rel in "$@"; do
  mkdir -p "$MIRROR/$(dirname "$rel")"
  rsync -az "${REMOTE_HOST}:${REMOTE_DIR}/${rel}" "$MIRROR/$(dirname "$rel")/"
done
SCRIPT
sudo chmod +x /usr/local/bin/c /usr/local/bin/cpull
```
> 非 root:放 `~/bin` 并加入 PATH。多项目:把这些变量抽到 `~/.config/remote-claude.<proj>.conf`,脚本 `source` 它。

### STEP 7 — 端到端 + 双向实时自测

```bash
c 'hostname; command -v uv && uv --version'                 # 执行 & 环境
# B->C
echo t1 > <MIRROR>/_t.txt; sleep 3; ssh <ALIAS> 'cat <REMOTE_DIR>/_t.txt'   # 应看到 t1
# C->B
ssh <ALIAS> 'echo t2 > <REMOTE_DIR>/_t2.txt'; sleep 3; cat <MIRROR>/_t2.txt # 应看到 t2
rm -f <MIRROR>/_t.txt <MIRROR>/_t2.txt                       # 删除也会双向传播
```

### STEP 8 — 写项目 `CLAUDE.md`(只留 B)并启动

在镜像根写一份操作说明 `CLAUDE.md`(把它加进 `.gitignore`,使其只留本地、不同步到远程)。然后:
```bash
cd <MIRROR> && tmux new -s dev && claude
```
从镜像目录启动,Claude 文件工具才作用在镜像上;`tmux` 保证断网重连不丢会话。

### STEP 9(可选)— 让 Mutagen 守护进程开机自启

`mutagen daemon start` 不会在重启后自动恢复。会话状态是持久化的,只要守护进程再起来就自动恢复同步。两种做法(需相应权限):
- **systemd(root)**:建 `/etc/systemd/system/mutagen.service`,`ExecStart=/usr/local/bin/mutagen daemon run`,`Environment=HOME=/root`,`Restart=on-failure`;`systemctl enable --now mutagen`。
- **cron**:`(crontab -l 2>/dev/null; echo '@reboot /usr/local/bin/mutagen daemon start') | crontab -`

---

## 五、日常使用

- **编辑代码**:B 或 C 任一边直接改,另一边 1~2 秒自动可见。
- **执行**用 `c '...'`,绝不在本机直接跑项目代码;长任务放 C 的 tmux(见下)。
  ```bash
  c 'nvidia-smi'
  c 'uv run python -m pkg.train'
  c "tmux new -d -s train 'bash train.sh 2>&1 | tee logs/run.log'"
  c 'tail -n 60 logs/run.log'
  c 'git add -A && git commit -m "..."'    # git 在 C
  ```
- **读被忽略目录里的结果**(日志/checkpoint,不参与实时同步):`cpull logs/run.log` 后再 Read。

---

## 六、性能与可靠性(诚实预期)

| 环节 | 表现 |
|---|---|
| 编辑/搜索代码 | 零延迟(本地镜像) |
| 文件同步到对端 | 秒级双向自动(取决于 RTT,小文件通常 1~3s) |
| `c` 执行命令 | 约 1 个热 RTT + 一次 flush |
| 任务运行中 | 零额外延迟(在 C 原生跑) |
| 链路抖动 | ControlMaster + Mutagen 自愈;跨境偶发 `Connection closed`,重试即可 |

---

## 七、排错

- **`uv`/`conda` not found**:登录 shell 没加载其 PATH。改 `c` 里的 `PATH_FIX`,补正确 bin 目录(`$HOME/miniconda3/bin`、`$HOME/.local/bin`、`$HOME/.cargo/bin`)。
- **大量 scan problems: invalid symbolic link**:软链指向绝对路径。已用 `--symlink-mode=ignore` 规避;若仍有,把相应目录加 `--ignore` 后 `mutagen sync terminate <NAME>` 再重建。
- **镜像/同步变得很大**:漏忽略了大目录。`du -sh <MIRROR>/*` 找出,加 `--ignore` 重建会话,删掉误同步的目录。
- **同步卡住**:`mutagen sync list <NAME>` 看状态;`mutagen sync reset <NAME>` 重置;`mutagen daemon start` 起守护。
- **改完立刻执行怕没同步**:不用担心,`c` 内置 `flush` 会等同步完成。
- **两边同时改同一文件 → conflict**:`mutagen sync list --long <NAME>` 看冲突项,手动改好一边即可。

---

## 八、迁移到新机器 / 新项目清单

1. (换新 B)STEP 1–2、STEP 4:密钥、`~/.ssh/config`、装 Mutagen。
2. STEP 3:摸清新项目大目录与环境。
3. STEP 5:改忽略清单,`mutagen sync create` 新会话(换 `<NAME>`/`<MIRROR>`/`<REMOTE_DIR>`)。
4. STEP 6:改 `c`/`cpull` 顶部的 `NAME`/`REMOTE_HOST`/`REMOTE_DIR`/`PATH_FIX`(多项目建议抽 conf)。
5. STEP 7–9:自测、写 CLAUDE.md、`cd <MIRROR> && claude`、(可选)开机自启。

---

## 附录:无外部依赖的备选(rsync-on-execute,不满足"实时")

无法/不愿装 Mutagen 时的降级方案。**不实时、单向**:仅在执行 `c` 时把改动 rsync 推到 C;C→B 只能手动 `cpull`。仅当"实时双向"不是硬需求时用。

`c` 的 rsync 版核心(替换 STEP 6 的 flush 那两行):
```bash
# 用指纹判断,仅当镜像变化才推;只读命令因此很快
STAMP="$HOME/.cache/rc-$(echo "$MIRROR"|md5sum|cut -c1-8).md5"; mkdir -p "$(dirname "$STAMP")"
cur=$(cd "$MIRROR" && find . -type f -printf '%P %s %T@\n'|LC_ALL=C sort|md5sum|cut -d' ' -f1)
[ "$cur" = "$(cat "$STAMP" 2>/dev/null||echo x)" ] || {
  rsync -az --delete --exclude-from="$EXCLUDE" "$MIRROR/" "$REMOTE_HOST:$REMOTE_DIR/" >/dev/null
  echo "$cur" > "$STAMP"; }
```
（`$EXCLUDE` 为与上文忽略清单等价的 rsync 排除文件。）
