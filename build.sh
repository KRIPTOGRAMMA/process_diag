#!/usr/bin/env bash
# process_diag — построить визуальную карту процессов (flowchart + ER) из графа graphify.
#
# Использование:
#   ./build.sh <путь-к-проекту>                             # для агента (см. INSTRUCTIONS.md)
#   ./build.sh <путь-к-проекту> --model <gemini-*|claude-*>  # автономно, через LLM API
#
# Требует, чтобы в <путь-к-проекту>/graphify-out/graph.json уже лежал построенный
# граф (запустить `/graphify <путь-к-проекту>` в Claude Code, если его ещё нет).
#
# Без --model скрипт только проверяет предпосылки и печатает инструкцию для
# агента (см. INSTRUCTIONS.md), который читает graph.json и заполняет
# template.html осмысленными диаграммами. С --model дополнительно вызывает
# generate.py, который делает то же самое сам через API (см. README.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=""
MODEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "Использование: ./build.sh <путь-к-проекту> [--model <gemini-*|claude-*>]"
  exit 1
fi

TARGET="$(cd "$TARGET" && pwd)"
GRAPH_JSON="$TARGET/graphify-out/graph.json"
GRAPH_REPORT="$TARGET/graphify-out/GRAPH_REPORT.md"

if [ ! -f "$GRAPH_JSON" ]; then
  echo "Граф не найден: $GRAPH_JSON"
  echo ""
  echo "Сначала построй граф кодовой базы:"
  echo "  /graphify $TARGET"
  echo ""
  echo "Затем запусти этот скрипт снова."
  exit 1
fi

OUT_NAME="$(basename "$TARGET")-processes.html"
OUT_PATH="$TARGET/$OUT_NAME"

if [ -f "$OUT_PATH" ]; then
  BACKUP_PATH="$OUT_PATH.bak"
  cp "$OUT_PATH" "$BACKUP_PATH"
  echo "Найден существующий файл — сохранена копия: $BACKUP_PATH"
fi

# template.html — полный HTML-документ, но содержит только init-скрипт
# (window.mermaid.initialize/run) в конце body; саму библиотеку mermaid.min.js
# нужно инлайнить перед ним, иначе `mermaid` не определён и диаграммы
# остаются сырым текстом внутри <pre>.
python3 - "$SCRIPT_DIR/template.html" "$SCRIPT_DIR/mermaid.min.js" "$OUT_PATH" << 'PYEOF'
import sys
from pathlib import Path

template_path, mermaid_path, out_path = sys.argv[1:4]
template = Path(template_path).read_text(encoding="utf-8")
mermaid_js = Path(mermaid_path).read_text(encoding="utf-8")

marker = "<script>\n  (function () {"
if marker not in template:
    raise SystemExit("marker not found in template.html - init script missing or changed")

lib_script = "<script>\n" + mermaid_js + "\n</script>\n"
template = template.replace(marker, lib_script + marker, 1)

Path(out_path).write_text(template, encoding="utf-8")
PYEOF

echo "Шаблон собран (с инлайн mermaid.js): $OUT_PATH"
echo "Граф найден: $GRAPH_JSON"
[ -f "$GRAPH_REPORT" ] && echo "Отчёт найден: $GRAPH_REPORT"

if [ -n "$MODEL" ]; then
  echo ""
  echo "Автономный режим: заполняю $OUT_PATH через модель $MODEL..."
  python3 "$SCRIPT_DIR/generate.py" "$TARGET" --model "$MODEL"

  echo ""
  echo "Проверка полноты заполнения..."
  "$SCRIPT_DIR/check_output.sh" "$OUT_PATH"
else
  echo ""
  echo "Дальше — задача для агента (LLM), не для этого скрипта:"
  echo "прочитать $SCRIPT_DIR/INSTRUCTIONS.md и заполнить $OUT_PATH"
  echo "диаграммами на основе graph.json / GRAPH_REPORT.md."
  echo ""
  echo "В Claude Code это делает skill: /process-diag $TARGET"
  echo "Либо автономно (без агента): ./build.sh $TARGET --model <gemini-*|claude-*>"
  echo ""
  echo "ВАЖНО: после заполнения агент обязан запустить перед сдачей:"
  echo "  $SCRIPT_DIR/check_output.sh $OUT_PATH"
  echo "Это не опционально — см. Шаг 5 в INSTRUCTIONS.md."
fi
