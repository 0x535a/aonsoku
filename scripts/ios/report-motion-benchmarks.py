"""Summarize a retrieved artwork JSONL trace; no cover IDs/URLs are emitted."""
import argparse
import json
import re
import statistics
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    batches = []
    current = None
    for line in args.trace.read_text().splitlines():
        try:
            message = json.loads(line)["message"]
        except (json.JSONDecodeError, KeyError):
            continue
        if message.startswith("comparison-start"):
            current = {"complete": False, "models": {}}
            batches.append(current)
        if current is None:
            continue
        if message.startswith("comparison-complete"):
            current["complete"] = True
        match = re.search(r"backend=([a-z0-9-]+)", message)
        if not match:
            continue
        model = current["models"].setdefault(match[1], {})
        fields = dict(re.findall(r"([A-Za-z]+)=([^\s]+)", message))
        if message.startswith("phase="):
            phase = fields["phase"]
            if phase == "model-load":
                model["warm"] = []
                model.pop("failed", None)
            record = {key: int(fields[key]) for key in
                      ["elapsedMs", "baselineMiB", "peakMiB", "deltaMiB"] if key in fields}
            if phase == "model-predict-warm":
                model.setdefault("warm", []).append(record.get("elapsedMs"))
            else:
                model[phase] = record
        elif message.startswith("comparison-result"):
            model["result"] = fields
        elif message.startswith("model failed"):
            model["failed"] = True
    if not batches:
        raise SystemExit("No comparison-start in trace")
    batch = batches[-1]
    if args.json:
        print(json.dumps(batch, indent=2))
        return
    print("| Candidate | Load ms | First prediction ms | Warm median ms | Total model peak / delta MiB | Encode ms | MP4 MiB | Result |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    for identifier, model in batch["models"].items():
        def time(phase):
            return model.get(phase, {}).get("elapsedMs", "—")
        total = model.get("model-total", model.get("analysis", {}))
        peak = f"{total.get('peakMiB', '—')} / {total.get('deltaMiB', '—')}"
        warm = statistics.median(model["warm"]) if model.get("warm") else "—"
        result = model.get("result", {})
        size = f"{int(result['bytes']) / 1048576:.2f}" if "bytes" in result else "—"
        status = "failed → fallback" if model.get("failed") else result.get("analysis", "not recorded")
        print(f"| {identifier} | {time('model-load')} | {time('model-predict-cold')} | {warm} | {peak} | {time('motion-encode')} | {size} | {status} |")
    print(f"\nBatch complete: {batch['complete']}. Memory is native-process footprint sampled every 10ms, not model file size; sequential loads can reuse OS caches.")


if __name__ == "__main__":
    main()
