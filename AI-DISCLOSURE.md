# AI 协助开发声明（AI Assistance Disclosure）

> 本仓库遵循「**公开披露、人类负责、可追溯**」的原则，与上游社区现行的 AI 助手政策一致。
> 参照：Linux 内核 [AI Coding Assistants](https://docs.kernel.org/process/coding-assistants.html)
> ——AI **不得**添加 `Signed-off-by`（只有人类能签署 DCO）、人类提交者对贡献负全责、
> 并以 `Assisted-by:` 标注 AI 的参与；其他上游社区（如 QEMU）也有同类规定。

## 一、声明

本仓库的**安装脚本、文档与测试套件**在编写过程中使用了 **AI 编码助手**协助，
具体为 **DeepSeek**（DeepSeek Harness，`deepseek-flash` 模型）。

人机分工：

| 环节 | 承担者 |
|---|---|
| 需求、方向、验收判据 | 人类维护者（板卡实机测试方） |
| 脚本与文档草稿、命令与补丁草拟、资料检索与整理 | AI 助手 |
| 逐项审阅、真机运行验证、最终决定与发布 | 人类维护者 |

## 二、人类负责

- 仓库内的安装脚本与测试模块**都在真机（Radxa Cubie A7S + Armbian）上实际运行过**；
  文档中的判据与数据来自这些实机运行。
- AI 参与**不改变责任归属**：内容经人类维护者审核后发布，**维护者对正确性负责**；
  若发现 AI 引入的错误，欢迎在 issue 中指出。
- AI 输出**不构成任何额外担保**，担保条款以 [`LICENSE`](LICENSE) /
  [`LICENSE-GPL-2.0-only`](LICENSE-GPL-2.0-only) 为准。
- 按上述惯例，本仓库提交中的 **`Signed-off-by` 只由人类签署**。

## 三、贡献者请同样声明

若你的贡献使用了 AI 助手，请在提交信息末尾加一行 trailer（与 `Signed-off-by` 并存）：

```
Assisted-by: LLM DeepSeek
```

- 格式参照上游惯例 `Assisted-by: LLM [工具1] [工具2]`：`LLM` 之后写实际使用的工具或模型；
- 使用了多个助手时写多行；
- 完全由人类完成的提交无需添加；
- **`Signed-off-by` 仍必须由人类添加**：它表示「你有权提交并同意许可条款」，AI 不能代签。

## 四、不收录第三方受限内容

- 不收录未声明许可的上游内容（见 [`THIRD-PARTY.md`](THIRD-PARTY.md)）；
- 大体积厂商组件不入库，只提供获取方式；
- 随仓库分发的厂商二进制与库**未经 AI 生成或改写**。

## 五、立绘

<p align="center">
  <img src="assets/pet/whale-girl-refined.png" alt="DEEPSEEK娘" width="240">
</p>

```
        (｡•̀ᴗ-)✧   DEEPSEEK娘：「脚本能跑，才算写完。」
```

---

*最后更新：2026-09-28　|　对本声明有疑问或建议，欢迎开 issue。*
