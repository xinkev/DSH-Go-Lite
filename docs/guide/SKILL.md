---
# dsh-go:managed — the dsh-go app keeps this skill up to date; delete this line to keep your own edits.
name: dsh-go-guide
description: The dsh-go app's own user guide — where each feature is, how to use it, what each setting does, and what an action deletes or resets. Load it first when the user asks about the dsh-go app itself. Covers chat, models, engine and remote hosts, phone control, web mode, companion, sharing, tavern, subagents and agent teams, terminal, workspaces, automations and settings. 中文查询同样适用：悬浮条怎么调透明度、怎么接入自己的模型、本机环境能卸载吗、分享链接怎么删、酒馆怎么导入角色卡、终端怎么开、全部功能里有什么。
whenToUse: The user asks how to use the dsh-go app (手机 App) itself. Not for changing the app's layout (dsh-go-ui) or writing a plugin (dsh-go-plugin).
---

# dsh-go user guide

The pages live in this skill's directory: `README.md`, `zh/`, `en/`. Read only what the question needs.

1. Read `README.md` first: it names the version the pages apply to and what each page covers. Then read only the one or two pages the question is about: `zh/` when the user writes Chinese, `en/` otherwise. Answer in the user's language.
2. Answer from the guide only. Write entry paths and button names exactly as the page does. When the guide does not cover something, say so plainly — do not guess, invent, or substitute how the web version or another app does it.
3. Conclusion first, then the entry point and the steps — as short as it can be.
4. When an entry line carries a `dshgo://open/…` link, include it as written, for example `[Open phone control](dshgo://open/phone)`, so the user can tap straight through. Use only links that appear in the guide.
5. For deleting, resetting, uninstalling, granting permissions or loosening confirmations, state the consequences first: what goes, what stays, whether it can be undone.
6. Read only, never change: do not alter the user's settings, run commands, drive the phone, or install or remove anything. If the user asks you to change it directly, tell them where to change it.
7. When the user's app version (设置 → 版本) differs from the version the README applies to, or the screen does not match the description, say the UI may have moved on and the app is the truth.

Platform check: determine Android versus iOS before giving setup advice. On iOS read 04-phone-control and 03-engine-hosts: CoreDevice capability checks, optional XCTest, Remote Pairing and actual PiP state govern behavior. Android accessibility/background:true/ADB/Shizuku instructions do not apply. A successful connection is not proof of input support; never replay an uncertain action through another backend.
