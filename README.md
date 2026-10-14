# MoonCDC

[![CI](https://github.com/tlhuecdkoyg/MoonCDC/actions/workflows/ci.yml/badge.svg)](https://github.com/tlhuecdkoyg/MoonCDC/actions/workflows/ci.yml)

**MoonBit Change Data Capture：SQLite 持久化变更捕获与可恢复增量投影。**

MoonCDC 为已有 SQLite 表安装事务内的行级触发器，记录带类型的增、删、改事件，提供一致性快照、消费者游标、JSON/JSONL 传输及目标库恢复。项目包含可复用 MoonBit 库和原生命令行工具。SQLite 引擎通过社区绑定复用，不计入本项目代码量。

## 适用场景

- **业务库 → 报表库**：首次快照初始化，随后仅应用变更。同步中断后根据目标库持久化游标恢复，并补齐遗漏的源端确认。
- **本地数据 → 下游索引或缓存**：导出包含 before/after 镜像的 JSONL，下游持久化处理结果后再确认。删除及主键变化显式可见；外部副作用仍需下游自行保证幂等。
- **按条件建立数据子集**：保留完整主键，选择和重命名列，按类型筛选行。进入筛选范围产生插入，离开产生删除；全部被过滤的批次仍推进游标。
- **同步任务运行检查**：查看消费者积压、预演应用、比较同一水位的数据、诊断结构/触发器变化，并按所有消费者的最低游标清理日志。

## 已实现能力

| 组件 | 能力 |
| --- | --- |
| 类型模型 | NULL、Int64、有限 Double、文本、BLOB；数值字符串编码、BLOB 十六进制编码 |
| 捕获 | 普通表持久化 AFTER 触发器；事务回滚不留下事件；复合主键及主键更新 |
| 初始化 | 同一事务读取快照、水位并登记消费者 |
| 增量消费 | 源标识隔离、日志连续性检查、批次预算、确认时比较旧游标 |
| SQLite 目标 | 数据与游标同事务提交；重放不重复应用；before-image 冲突时整批回滚 |
| 筛选投影 | 类型严格的过滤器、列选择/重命名、目标持久化规则、防止恢复时偷换规则 |
| 传输 | JSON、带 header/commit 的 JSONL；增量批次解码、截断检测、分批/合批、相邻事件压缩 |
| 运维 | 暂停/恢复、消费者分叉和检查点登记、保留策略预览、分批清理、诊断、审计、安全卸载 |

## 工具链与依赖

验证基线为 **2026-10-12 发布的 MoonBit `v0.10.15+943464bfa`**，对应 `moon 0.1.20261012 (748b63c)`。

- `moonbit-community/sqlite3@0.2.3`（该版本内置 SQLite 3.49.1）
- `moonbitlang/async@0.22.4`、`moonbitlang/x@0.5.5`
- 原生构建需要 C 编译器：Windows 使用 MSVC，Linux 使用 GCC/Clang。
- 测试脚本使用 Python 3.12+；JS 测试需要 Node.js 22+。

安装指定版本时设置官方安装器的 `MOONBIT_INSTALL_VERSION=0.10.15+943464bfa`，参见 [MoonBit 安装说明](https://www.moonbitlang.com/download/)。纯类型/传输/筛选模块支持 native、JS 和 wasm-gc；SQLite 适配器与 CLI 仅支持 native。

## 快速运行

```sh
moon update
moon build --target native
moon run cmd/main --target native -- help
python examples/demo.py
```

示例创建临时源库和目标库，通过独立 Python SQLite 连接写入，再调用 CLI 同步并审计，不修改已有数据库。

实际数据库示例（`source.db` 必须已存在，`report.db` 必须尚不存在）：

```sh
moon run cmd/main --target native -- plan source.db orders customers
moon run cmd/main --target native -- install source.db orders customers
moon run cmd/main --target native -- bootstrap source.db report.db reporting
moon run cmd/main --target native -- sync source.db report.db reporting
moon run cmd/main --target native -- audit source.db report.db
moon run cmd/main --target native -- status source.db
moon run cmd/main --target native -- retention source.db
moon run cmd/main --target native -- prune-bounded source.db --limit 1000
```

**每个写入源库的连接必须执行 `PRAGMA recursive_triggers=ON`。** 捕获触发器拒绝不符合条件的写入，防止 `REPLACE` 隐式删除漏记。MoonCDC 自身连接自动设置，外部应用需自行设置。

完整操作和恢复见 [使用手册](docs/OPERATIONS.md)，协议见 [传输格式](docs/WIRE.md)，一致性边界见 [设计契约](docs/DESIGN.md)。

## 作为库使用

包导入 `tlhuecdkoyg/MoonCDC` 与 `tlhuecdkoyg/MoonCDC/sqlite`。SQLite API 为同步、可抛错 API：

```moonbit
let source = @sqlite.Database::open("source.db")
defer source.close()
let target = @sqlite.Database::open("report.db")
defer target.close()
source.install_capture(["orders"]) |> ignore
target.initialize_projection(source.snapshot("reporting"))
@sqlite.synchronize(source, target, "reporting") |> ignore
```

安装与快照仅在初始化时执行；恢复直接调用 `synchronize`。完整 API 参见各包 `pkg.generated.mbti` 与 SQLite 测试。

## 正确性边界

- 这是行级变更流与最终一致投影。一个源事务可能跨多个目标批次，不保留任意源事务的边界，不承诺跨系统 exactly-once。
- 安装改变源库结构并增加写入开销。首次快照持有写锁；大规模初始数据需评估锁等待和内存。
- 不支持虚拟表、隐藏/生成列、无显式主键的表、非 BINARY 主键排序规则或自动 DDL 迁移。结构变化需重新初始化。
- 目标表不复制源库索引、外键、其他约束和业务触发器，应由同步任务专用；外部修改可能导致后续应用失败。
- 同一目标的筛选规则不可变，修改需要新快照和新目标。独立 `project-*` 传输变换由调用方负责规则一致性。
- 快照和批次在预算内保存在内存；逐事件读取限制累积量，但单条 SQLite 值仍需解码。wire budget 使用 UTF-16 代码单元，CLI 输入预算使用文件字节。
- 不抵御恶意元数据修改。检测结构漂移和日志缺口不等于恢复已经丢失的事件。
- 快照文件输出、目标初始化与源端登记不构成跨资源事务。失败可能留下消费者登记或空目标文件，按手册处理；不自动删除用户文件。

## 验证与代码统计

```sh
python scripts/verify.py
python scripts/count_loc.py
```

验证包含格式/编译检查、三个后端的适用测试、原生构建，以及 CLI 独立进程与 Python SQLite 集成测试。覆盖外部写入、Int64/NUL 文本/BLOB/实数、持久化恢复、终止未提交写入、重放、筛选、截断输入、保留策略和目标分歧。

统计只计生产 `.mbt` 非空、非注释行，排除测试、示例、生成接口、依赖、构建产物、帮助文本和 `traits.mbt`。正常代码的括号与声明行计入，SQLite 引擎及 Python 测试不计入 4,000 行要求。

## 原创与许可证

捕获协议、游标恢复、筛选投影、运维接口及 CLI 为本项目实现，非现有 CDC 工具的移植。复用依赖及许可证见 [NOTICE](NOTICE)。本项目采用 [Apache-2.0](LICENSE)。
