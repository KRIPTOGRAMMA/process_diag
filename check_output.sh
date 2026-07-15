#!/usr/bin/env bash
# check_output.sh — проверка полноты заполнения <project>-processes.html.
#
# Использование: ./check_output.sh <путь-к-файлу.html>
#
# Проверяет две вещи, которые легко пропустить при заполнении шаблона руками:
#   1. Не осталось ли незаполненных {{PLACEHOLDER}} плейсхолдеров.
#   2. Не остались ли <br/> внутри диаграмм (баг: слова слипаются без переноса).
#
# Библиотека mermaid.min.js инлайнится в <script> в конце файла и содержит
# свои "{{"/"}}"-подобные паттерны в минифицированном коде парсера — это не
# баг, поэтому обе проверки ограничены содержимым ДО первого <script>.
#
# Exit code 0 — всё чисто. Exit code 1 — есть проблемы, разбор в stdout.
# Агент обязан прогнать этот скрипт перед тем, как показать результат готовым
# (см. INSTRUCTIONS.md, Шаг 5) и не имеет права сдавать файл с ненулевым exit.

set -uo pipefail

FILE="${1:-}"

if [ -z "$FILE" ]; then
  echo "Использование: $0 <путь-к-файлу.html>"
  exit 1
fi

if [ ! -f "$FILE" ]; then
  echo "Файл не найден: $FILE"
  exit 1
fi

FIRST_SCRIPT_LINE="$(grep -n '<script>' "$FILE" | head -1 | cut -d: -f1)"

if [ -z "$FIRST_SCRIPT_LINE" ]; then
  echo "ПРЕДУПРЕЖДЕНИЕ: тег <script> не найден — проверяю весь файл целиком."
  CONTENT_END=$(wc -l < "$FILE")
else
  CONTENT_END=$((FIRST_SCRIPT_LINE - 1))
fi

FAIL=0

PLACEHOLDER_COUNT=$(head -n "$CONTENT_END" "$FILE" | grep -oE '\{\{[A-Z_]+\}\}' | sort -u | wc -l)
if [ "$PLACEHOLDER_COUNT" -gt 0 ]; then
  echo "FAIL: найдены незаполненные плейсхолдеры ($PLACEHOLDER_COUNT уникальных):"
  head -n "$CONTENT_END" "$FILE" | grep -noE '\{\{[A-Z_]+\}\}' | sort -u -t: -k2
  FAIL=1
fi

BR_COUNT=$(head -n "$CONTENT_END" "$FILE" | grep -c '<br/>')
if [ "$BR_COUNT" -gt 0 ]; then
  echo "FAIL: найдено $BR_COUNT вхождений <br/> в содержимом (до первого <script>):"
  head -n "$CONTENT_END" "$FILE" | grep -n '<br/>'
  echo "Замени на настоящий перенос строки внутри кавычек лейбла (см. INSTRUCTIONS.md, Шаг 3)."
  FAIL=1
fi

MERMAID_COUNT=$(grep -c 'class="mermaid"' "$FILE")
echo "Найдено mermaid-блоков: $MERMAID_COUNT (домены + карта доменов + ER = ожидаемое число)"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: плейсхолдеров и <br/> в содержимом не найдено."
  exit 0
else
  echo ""
  echo "Файл НЕ готов к сдаче. Исправь найденное и прогони проверку снова."
  exit 1
fi
