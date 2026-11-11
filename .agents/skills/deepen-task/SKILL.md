---
name: deepen-task
description: Deepen a task or prompt the way a top professional in its field would - name what the expert would do that was not asked, the rawest source material, the specific methods and tools, and the outside evidence that shows the result is right - then rewrite the prompt to ask for exactly that. Use when the user asks to make a task or prompt deeper, more rigorous, more professional, "how would an expert do this", or invokes /deepen-task. Not for making a task bigger.
notion_page_id: 3fa32c21-5086-8149-b8b2-d56a884721cb
---

Source of truth: Notion skill https://app.notion.com/p/3fa32c2150868149b8b2d56a884721cb - edit there, then re-sync this file.

Deepen a task or prompt the way a top professional in its field would approach it, then rewrite the prompt to ask for that deeper version.

Use when the user asks to make a task "deeper", "more rigorous", "more professional", or "how would an expert do this", or invokes `deepen-task` on a prompt or task.

Do not use it to make a task bigger. Deeper means closer to source material, stronger methods, and outside verification. It does not mean more scope, more deliverables, or more length.

Do not execute the task itself unless the user asks for that after seeing the rewrite.

## Input

- The user's task or prompt. If none is given, use the most recent task in the conversation. If no task is identifiable, ask for it in one question.
- Optional: the field or domain. Infer it from the task when it is not stated, and name the field you assumed.

## Steps

Answer these four questions first, before rewriting anything. Be specific to this task and field; avoid generic advice that would fit any task.

1. **What a top professional would do that the user is not asking for.** Name the concrete moves an expert in this field would make here: the question they would reframe, the step they would never skip, the failure they would check for. Limit to the 3-5 that matter most.
2. **The rawest material they would start from.** Name the primary sources an expert would go to instead of the pre-digested material the user has (summaries, articles, AI answers, dashboards, secondhand reports). Examples of raw material: original data, logs, source code, transcripts, contracts, filings, field observations, the primary paper, the user's own customers. Say where to get each one.
3. **The specific methods and tools they would use.** Name actual methods, frameworks, techniques, and tools by name, and say what each contributes to this task. Prefer field-standard methods over invented ones.
4. **What, other than the assistant or the user, would show the result is right.** Name independent evidence: a test that can fail, a measurement, a benchmark, a domain expert's review, real-world behavior, a reproduction, a comparison against ground truth. State what result would show the work is wrong.

Then:

1. **Rewrite the prompt** so it asks for exactly that deeper version: it names the raw material to start from, the methods and tools to use, and the independent check that defines done. Keep the user's original goal and scope. Do not add new goals or deliverables.
2. Keep the rewrite self-contained so it can be pasted into a fresh session with any agent.

## Output

Return, in this order:

1. The four answers, under short headings.
2. The rewritten prompt in a single copyable code block.
3. One line naming any assumption you made (field, available data, tools) that the user should confirm.

Answer in the language the user writes in.

## Edge cases

- If the raw material is not accessible (private, paid, or does not exist yet), say so and name the closest obtainable substitute in the rewrite.
- If a named tool is unavailable to the agent that will run the task, keep it in the rewrite only if the user can run it; otherwise name an available alternative.
- If the task is already at expert depth, say what is already right and change only what adds depth.
- If the field is ambiguous and the answer would differ materially between fields, ask one question before answering.

## Check before delivery

- Each of the four answers is specific to this task, not boilerplate.
- The rewrite is deeper, not larger: same goal, same scope, no extra deliverables.
- The rewrite names a verification that could fail.
