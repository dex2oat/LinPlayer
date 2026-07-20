#!/usr/bin/env bash
# 校验 .github/workflows/*.yml 里每个 `run:` 块的 **shell 语法**。
#
# 为什么单独要这个:`yaml.safe_load` 过不代表脚本是好的。
# 用脚本批量改 workflow 时切多了几行,结果是
#     run: |
#       if [ ! -d x ]; then          <-- then 之后全没了
# 这仍然是**完全合法的 YAML**,只有 runner 跑到那一步才报
#     syntax error: unexpected end of file
# 烧掉一整轮 CI 才发现。本项目已经这样栽过两次(一次回车符混进脚本,一次切多了行)。
#
# 只查 bash/sh 的块;pwsh 的块跳过(要 PowerShell 才能解析,本地不一定有)。
#
# 用法:bash scripts/check-workflows.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# ★ 临时目录用 mktemp,不写死 /tmp —— Windows 上的 python 会把 "/tmp" 解释成
#   盘符根下的 tmp 目录,而它通常不存在,直接 FileNotFoundError。
#   路径经环境变量传给 python,避免在 python 源码里出现 Windows 路径分隔符。
# ★ 不能只靠 `command -v` 挑解释器。Windows 上 `python3` 会命中微软商店的**空壳**
#   (WindowsApps 里那个),它什么都不干、直接退出 49 —— 而 command -v 认为它存在。
#   所以逐个**实跑一下**,谁真能执行用谁。CI(ubuntu)上是 python3,本地是 python。
PY_BIN=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import yaml" >/dev/null 2>&1; then
    PY_BIN="$c"; break
  fi
done
[ -n "$PY_BIN" ] || { echo "找不到带 PyYAML 的 python(pip install pyyaml)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export WORK

"$PY_BIN" - <<'PY'
import yaml, glob, json, os

out = []
for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = yaml.safe_load(open(f, encoding='utf-8'))
    for jname, job in (d.get('jobs') or {}).items():
        job_shell = ((job.get('defaults') or {}).get('run') or {}).get('shell')
        for i, step in enumerate(job.get('steps') or []):
            run = step.get('run')
            if not run:
                continue
            shell = step.get('shell') or job_shell or 'bash'
            if 'pwsh' in shell or 'powershell' in shell:
                continue
            out.append({
                'label': '%s | %s | %s' % (f, jname, step.get('name') or ('#%d' % i)),
                'run': run,
            })

w = os.environ['WORK']
for i, b in enumerate(out):
    # newline='\n':GitHub runner 上是 LF。带回车符的脚本 bash 会报怪错,
    # 那正是本项目栽过的第一次(回车符被当成命令的一部分)。
    with open('%s/%d.sh' % (w, i), 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(b['run'])
with open(w + '/labels.txt', 'w', encoding='utf-8', newline='\n') as fh:
    # ★ 每行都要带结尾换行。用 '\n'.join 的话最后一行没有换行符,下面的
    #   `while read` 会**静默丢掉最后一块** —— 实测 35 块只查了 34 块,
    #   而"最后一个步骤坏掉"恰恰是脚本批量改文件时最容易造出来的情况。
    for b in out:
        fh.write(b['label'] + '\n')
print(len(out))
PY

n=$("$PY_BIN" -c "import os;print(sum(1 for _ in open(os.environ['WORK']+'/labels.txt',encoding='utf-8')))")
echo "待查 shell 块: $n"

fail=0
i=0
while IFS= read -r label; do
  if ! err=$(bash -n "$WORK/$i.sh" 2>&1); then
    echo "  FAIL  $label"
    echo "        $err"
    fail=1
  fi
  i=$((i + 1))
done < "$WORK/labels.txt"

if [ "$fail" -ne 0 ]; then
  echo "workflow 里有 shell 语法错误"
  exit 1
fi
echo "全部通过($i 块)"
