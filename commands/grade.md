---
allowed-tools: Bash
description: Grade benchmark results against SLO thresholds (A-F) for each provider
argument-hint: <report.json> [--thresholds slos.json]
---

## Context
- Plugin root: ${CLAUDE_PLUGIN_ROOT}
- Arguments: $ARGUMENTS

## Your Task

Grade a benchmark report against SLO thresholds and present the results.

### Steps

1. The first argument should be the path to a benchmark JSON report file.
   If no argument is provided, check if a recent report exists.

2. Run the grading script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/grade.sh <report.json> [--thresholds <slos.json>]
   ```

3. Present the grades clearly:
   - Overall grade per provider (A = excellent, F = critical)
   - Per-metric grades showing which metrics are healthy vs degraded
   - If any metric is D or F, call it out as needing attention

4. If both providers are graded, compare:
   - Which has the better overall grade?
   - Which specific metrics differ in grade between providers?
