#!/usr/bin/env python3
"""Автономная генерация process_diag через LLM API (без агента Claude Code).

Использование:
  python3 generate.py <project-path> --model <model-name>

Модели:
  gemini-*  -> Gemini API, ключ в GEMINI_API_KEY
  claude-*  -> Anthropic Messages API, ключ в ANTHROPIC_API_KEY

Читает graph.json / GRAPH_REPORT.md / INSTRUCTIONS.md, просит модель вернуть
JSON с готовым содержимым для каждого плейсхолдера template.html, подставляет
в скопированный шаблон и пишет <project>-processes.html.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

PLACEHOLDERS = [
    "PAGE_TITLE",
    "PROJECT_LABEL",
    "PAGE_H1_SHORT",
    "EYEBROW",
    "PAGE_H1",
    "PAGE_INTRO",
    "NAV_LINKS",
    "DOMAIN_SECTIONS",
    "MAP_SECTION",
    "ER_SECTION",
    "PATTERNS_SECTION",
]

GEMINI_ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
)
ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"


def build_prompt(instructions: str, graph_report: str, graph_json: str) -> str:
    placeholders_list = "\n".join(f"- {name}" for name in PLACEHOLDERS)
    return f"""{instructions}

## Данные графа

### GRAPH_REPORT.md
{graph_report}

### graph.json
{graph_json}

## Формат ответа

Ты работаешь без человека-агента, поэтому верни ответ СТРОГО как один JSON-объект
(без markdown-обёртки ```json, без пояснений до/после) с ключами ровно такими:

{placeholders_list}

Каждое значение — готовый HTML-фрагмент (или простой текст для коротких
плейсхолдеров типа PAGE_TITLE), который будет подставлен напрямую в
template.html вместо {{{{PLACEHOLDER}}}}. Соблюдай все правила mermaid-синтаксиса
из инструкции выше (особенно про переносы строк — реальный перевод строки,
никогда \\n или <br/> внутри лейблов).
"""


def call_gemini(model: str, prompt: str) -> str:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        raise SystemExit("error: GEMINI_API_KEY не установлен")
    url = GEMINI_ENDPOINT.format(model=model, key=key)
    payload = {"contents": [{"parts": [{"text": prompt}]}]}
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"error: Gemini API вернул {exc.code}: {body}") from exc
    return data["candidates"][0]["content"]["parts"][0]["text"]


def call_anthropic(model: str, prompt: str) -> str:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise SystemExit("error: ANTHROPIC_API_KEY не установлен")
    payload = {
        "model": model,
        "max_tokens": 16000,
        "messages": [{"role": "user", "content": prompt}],
    }
    req = urllib.request.Request(
        ANTHROPIC_ENDPOINT,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "x-api-key": key,
            "anthropic-version": ANTHROPIC_VERSION,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"error: Anthropic API вернул {exc.code}: {body}") from exc
    return data["content"][0]["text"]


def call_model(model: str, prompt: str) -> str:
    if model.startswith("gemini"):
        return call_gemini(model, prompt)
    if model.startswith("claude"):
        return call_anthropic(model, prompt)
    raise SystemExit(f"error: неизвестный провайдер для модели '{model}' (ожидался префикс gemini-* или claude-*)")


def extract_json(text: str) -> dict[str, str]:
    stripped = text.strip()
    fence_match = re.match(r"^```(?:json)?\s*(.*?)\s*```$", stripped, re.DOTALL)
    if fence_match:
        stripped = fence_match.group(1)
    try:
        return json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"error: не удалось распарсить JSON-ответ модели: {exc}\n\nОтвет модели:\n{text}") from exc


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_path")
    parser.add_argument("--model", required=True, help="например gemini-2.5-flash или claude-haiku-4-5-20251001")
    args = parser.parse_args()

    target = Path(args.project_path).resolve()
    graph_json_path = target / "graphify-out" / "graph.json"
    graph_report_path = target / "graphify-out" / "GRAPH_REPORT.md"
    instructions_path = SCRIPT_DIR / "INSTRUCTIONS.md"
    # build.sh уже собрал этот файл из template.html + инлайн mermaid.min.js
    # до вызова generate.py — здесь только подставляются плейсхолдеры.
    template_path = target / f"{target.name}-processes.html"

    if not graph_json_path.exists():
        raise SystemExit(f"error: граф не найден: {graph_json_path}\nСначала построй граф: /graphify {target}")

    if not template_path.exists():
        raise SystemExit(f"error: собранный шаблон не найден: {template_path}\nЗапускай через build.sh, а не напрямую.")

    instructions = instructions_path.read_text(encoding="utf-8")
    graph_report = graph_report_path.read_text(encoding="utf-8") if graph_report_path.exists() else "(нет GRAPH_REPORT.md)"
    graph_json = graph_json_path.read_text(encoding="utf-8")

    prompt = build_prompt(instructions, graph_report, graph_json)

    print(f"Отправляю запрос модели {args.model}...", file=sys.stderr)
    response_text = call_model(args.model, prompt)
    sections = extract_json(response_text)

    missing = [name for name in PLACEHOLDERS if name not in sections]
    if missing:
        raise SystemExit(f"error: модель не вернула значения для: {', '.join(missing)}")

    # build.sh уже сделал бэкап .bak до сборки этого файла, если он существовал раньше.
    filled = template_path.read_text(encoding="utf-8")
    for name in PLACEHOLDERS:
        filled = filled.replace("{{" + name + "}}", sections[name])
    template_path.write_text(filled, encoding="utf-8")
    print(f"Готово: {template_path}", file=sys.stderr)

    br_count = len(re.findall(r"<br/>", filled.split("<script>", 1)[0] if "<script>" in filled else filled))
    print(f"Проверка: grep -c '<br/>' {template_path}  (0 ожидается вне inline mermaid.min.js)", file=sys.stderr)
    if br_count:
        print(f"ВНИМАНИЕ: найдено {br_count} '<br/>' до inline-скрипта mermaid — проверь диаграммы вручную.", file=sys.stderr)


if __name__ == "__main__":
    main()
