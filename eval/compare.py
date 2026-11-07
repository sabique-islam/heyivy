#!/usr/bin/env python3
"""Compares two lesson eval runs case by case, for a prompt or model change (drawing plan, D6).

    python3 eval/compare.py eval/results/<before>/results.json eval/results/<after>/results.json

Cases are paired, so only cases both runs share are compared, and each case counts once
however many trials it had. It prints the pass rate of each run, the change for each
screen type, and every case that went from passing to failing or back.

One run of a case is one sample of an answer that varies. A case that flips may just be
noise, so run --trials 3 or more before reading much into a small difference. Nothing here
claims significance.
"""
import json
import sys
from collections import defaultdict


def load(results_path):
    with open(results_path, encoding="utf-8") as results_file:
        results = json.load(results_file)
    pass_counts = defaultdict(lambda: [0, 0])
    categories = {}
    wrong_marks = defaultdict(int)
    for trial in results["trials"]:
        counts = pass_counts[trial["caseID"]]
        counts[0] += 1 if trial["passed"] else 0
        counts[1] += 1
        categories[trial["caseID"]] = trial["category"]
        wrong_marks[trial["caseID"]] += trial["marksElsewhere"] + trial["marksOnHostile"]
    pass_rates = {case_id: passed / total for case_id, (passed, total) in pass_counts.items()}
    return results["run"], pass_rates, categories, wrong_marks


def percent(value):
    return f"{value * 100:.0f}%"


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        raise SystemExit(2)
    before_run, before_rates, categories, before_wrong = load(sys.argv[1])
    after_run, after_rates, after_categories, after_wrong = load(sys.argv[2])
    categories.update(after_categories)
    shared_cases = sorted(set(before_rates) & set(after_rates))
    if not shared_cases:
        print("The runs share no cases.")
        raise SystemExit(1)

    def describe(run):
        return f"{run['label']} (prompt {run['promptSHA256Prefix']}, {run['modelNote']}, split {run['split']}, {run['trials']} trial(s))"

    print(f"Before: {describe(before_run)}")
    print(f"After:  {describe(after_run)}")
    if before_run["promptSHA256Prefix"] == after_run["promptSHA256Prefix"] and before_run["modelNote"] == after_run["modelNote"]:
        print("Same prompt and model, so any difference is run-to-run variation.")
    unshared = set(before_rates) ^ set(after_rates)
    if unshared:
        print(f"{len(unshared)} case(s) are in only one run and are left out.")

    before_mean = sum(before_rates[case_id] for case_id in shared_cases) / len(shared_cases)
    after_mean = sum(after_rates[case_id] for case_id in shared_cases) / len(shared_cases)
    print(f"\nPassed, over {len(shared_cases)} shared cases: {percent(before_mean)} -> {percent(after_mean)}")
    print(f"Wrong marks: {sum(before_wrong[c] for c in shared_cases)} -> {sum(after_wrong[c] for c in shared_cases)}")

    print("\nBy screen type:")
    by_category = defaultdict(list)
    for case_id in shared_cases:
        by_category[categories[case_id]].append(case_id)
    for category, case_ids in sorted(by_category.items()):
        before_category = sum(before_rates[c] for c in case_ids) / len(case_ids)
        after_category = sum(after_rates[c] for c in case_ids) / len(case_ids)
        change = after_category - before_category
        print(f"  {category:22} {len(case_ids):3} cases  {percent(before_category):>5} -> {percent(after_category):>5}  ({'+' if change >= 0 else ''}{change * 100:.0f} points)")

    got_worse = [c for c in shared_cases if after_rates[c] < before_rates[c]]
    got_better = [c for c in shared_cases if after_rates[c] > before_rates[c]]
    if got_worse:
        print("\nWorse: " + ", ".join(f"{c} ({percent(before_rates[c])} -> {percent(after_rates[c])})" for c in got_worse))
    if got_better:
        print("Better: " + ", ".join(f"{c} ({percent(before_rates[c])} -> {percent(after_rates[c])})" for c in got_better))


if __name__ == "__main__":
    main()
