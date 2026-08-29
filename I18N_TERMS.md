# Arbor i18n 术语表

UI 支持 `en` 和 `zh-Hans`。Git/版本控制术语在中文界面保留英文，避免和 Git 命令、提交信息及社区惯例产生歧义。

| English | zh-Hans UI | 备注 |
|---|---|---|
| commit | commit | 提交动作和提交对象 |
| amend | amend | 修改最近一次提交 |
| rebase | rebase | 不翻译 |
| pick | pick | rebase 动作 |
| drop | drop | rebase/stash 动作 |
| squash | squash | rebase 动作 |
| reword | reword | rebase 动作 |
| edit | edit | rebase 动作 |
| cherry-pick | cherry-pick | 应用指定提交 |
| revert | revert | 生成反向提交 |
| reset | reset | 移动 HEAD/索引/工作区 |
| stash | stash | Git 原生临时保存 |
| shelve | Shelve | Arbor 本地补丁保存 |
| unshelve | unshelve | 应用本地补丁 |
| fetch | fetch | 获取远程对象 |
| pull | pull | 获取并整合远程变更 |
| push | push | 推送本地变更 |
| force | force | 强制推送开关 |
| follow | follow | 文件历史跟随重命名 |
| HEAD | HEAD | 当前提交指针 |
| branch | branch | 分支 |
| tag | tag | 标签 |
| merge | merge | 合并 |
| hook | hook | Git hook |
| diff | diff | 差异 |
| blame | blame | 逐行归属 |
| PR | PR | Pull Request |
| issue | issue | 托管平台 issue |

普通产品文案（例如“提交信息”“工作区”“选择文件”）正常翻译；提交信息本身不经过 UI 本地化。
