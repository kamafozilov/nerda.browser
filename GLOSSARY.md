# Nerda

A macOS browser on WebKit, built to be its owner's only browser, used by hand and by the AI agents working for them.

## Agents

**Agent**:
An AI assistant outside Nerda, such as Claude Code or Codex, that the owner asks to do something which needs a browser, and which then uses Nerda on their behalf.
_Avoid_: bot, automation, AI (for Nerda's own features)

**Agent session**:
One **Agent**'s piece of work in Nerda, from its first request to when it stops, holding its **Agent tabs**.
_Avoid_: job, run, connection

**Agent tab**:
A tab an **Agent** opened for its **Agent session**, in the owner's own profile with their sign-ins, kept out of the owner's tab list and reached through the **Agent row**.
_Avoid_: automation tab, background tab

**Agent row**:
The one row at the foot of the sidebar that says which **Agents** are at work or waiting for the owner, and opens their **Agent tabs**.
_Avoid_: agent group, agent folder

**Handoff**:
The moment an **Agent** stops and asks the owner to do a step only a person can do, such as signing in, a 2FA code, a captcha or a passkey, and then carries on.
_Avoid_: interrupt

**Take over**:
The owner taking an **Agent tab** into their own hands mid-task, the **Agent** waiting until it is handed back.
_Avoid_: handoff (that is the agent asking)

**Site skill**:
Written know-how about one site that an **Agent** is pointed to when it reaches that site.
_Avoid_: recipe, playbook

## Speed

**Latency**:
The time from the owner's action to the first thing they see or hear in answer to it.
_Avoid_: delay, lag

**Budget**:
The most **Latency** an action may have before it counts as a fault.
_Avoid_: target, limit

**Hitch**:
A moment of 100 ms or more in which Nerda itself answers nothing.
_Avoid_: stop, freeze, jank

**Stall**:
A **Hitch** that lasts a second or more.
_Avoid_: hang (that is a page that stopped answering)

## Media

**Dropout**:
A gap in the sound or picture of media that should be playing.
_Avoid_: interruption, cut, glitch

**Floating player**:
A page's video shown out of its page, over every window, while the owner is somewhere else.
_Avoid_: PiP, mini player, pop-out (Picture in Picture names the setting and the system's mechanism)
