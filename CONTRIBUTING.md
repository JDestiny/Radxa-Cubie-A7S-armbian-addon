# 贡献指南（Contributing）

本仓库是 **Radxa Cubie A7S（Allwinner A733 / sun60iw2）** 的 Armbian 附加组件仓库
（驱动、用户态、配置脚本与其说明），与 [Armbian build](https://github.com/armbian/build) 的板级支持配套。

## 一、提交信息的规范

参照 Armbian 上游的板级/组件提交习惯：

```
<组件或板名>: <祈使句、小写、不加句号>

正文说明「为什么」与「怎么验证」，必要时给出命令与实测数据。
```

示例：

```
gpu: install the gpuacct DKMS variant by default

The stock blob does not expose the GPU accounting counters used by the
monitoring scripts; switch the default to the gpuacct variant and keep
the stock one behind a flag.
```

- 一行标题 ≤ 72 字符；标题与正文之间空一行；
- **不要**出现项目内部的分类代号（如「A 类 / B 类」）——那是本地测试用语，不属于上游语义；
- 一个提交只做一件事；格式化与逻辑改动分开提交。

## 二、脚本规范

- 一律 `#!/bin/bash`（确需 POSIX 兼容时才用 `#!/bin/sh`），文件行尾 **LF**（见 `.gitattributes`）；
- 文件头写清：**用途 / 用法 / 依赖 / 是否需要 root**；
- 改动脚本必须通过 `bash -n` 语法检查；有条件时跑 `shellcheck`（`-S warning`），
  至少不得引入新的 **SC2164（`cd` 未判错）** 与 **SC2242（`exit` 参数越界）** 类问题；
- 安装类脚本需**幂等**：重复执行不破坏已有配置；破坏性动作必须先备份并提示；
- 不要提交运行期产物与厂商大体积二进制（见 `.gitignore`），大组件按组件 README 自行获取。

## 三、文档规范

- 面向使用者的说明（`README.md`、各组件 `README.md`、`安装流程-六步.md`）用**中文**；
- 代码注释、提交信息用**英文**（与上游一致）；
- 结论要写**依据**（命令 + 原始数据），被推翻的结论**保留并标注撤回**，不静默删除。

## 四、测试与验收

- 每个组件需附**判据 + 复现命令 + 已知缺口**；
- 硬件相关改动请注明实测环境（板型 / 内核版本 / 颗粒或器件型号）。

## 五、许可

- 本仓库整体见 `LICENSE`；第三方组件与固件的来源与许可见 `THIRD-PARTY.md`；
- 新增第三方内容必须同时在 `THIRD-PARTY.md` 登记来源与许可。
