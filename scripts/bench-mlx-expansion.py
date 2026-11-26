#!/usr/bin/env python3
"""
Reproducible local MLX benchmark for Arbor Phase 1d (Smart Search Term Expansion).

Evaluates quantized MLX models (0.6B/0.8B/2B/4B/9B, 4-bit vs 8-bit) on bilingual
Spanish/English/Developer file-search queries, measuring:
  - Cold model load time (s)
  - Peak MLX Metal memory (GB) & Process RSS (GB)
  - Median & P95 query latency (ms) and throughput (tok/s)
  - Strict JSON compliance (%)
  - Relevance (Hit@Expected %, avg expected matches/query)
  - Noise rate (% overly generic stopwords, echo duplicates, or verbose phrases)

Run with Homebrew's mlx-lm interpreter:
  /opt/homebrew/Cellar/mlx-lm/*/libexec/bin/python scripts/bench-mlx-expansion.py \
      --models mlx-community/Qwen3-0.6B-4bit mlx-community/Qwen3.5-2B-4bit
"""

import argparse
import gc
import json
import os
import re
import resource
import statistics
import sys
import time
import unicodedata
from pathlib import Path

import mlx.core as mx
from mlx_lm import generate, load
from mlx_lm.sample_utils import make_logits_processors, make_sampler

SYSTEM_PROMPT = """You expand desktop file-search queries into concise related search keywords.
Output ONLY a JSON array of 5 distinct lowercase search tokens (synonyms, cross-language translations, common vendor/format/code identifiers) likely to appear in matching filenames or file contents.

Rules:
- Output ONLY a valid JSON array of strings, nothing else.
- Each token is 1 word (or short snake_case / hyphen identifier).
- Never repeat words already in the query or duplicate tokens.
- Avoid generic words: file, document, folder, data, info, text, pdf, code, archivo, documento."""

FEW_SHOT_TURNS = [
    {"role": "user", "content": "Search mode: name\nQuery: factura gas"},
    {"role": "assistant", "content": '["metrogas","naturgy","invoice","bill","utility"]'},
    {"role": "user", "content": "Search mode: content\nQuery: crash report"},
    {"role": "assistant", "content": '["stacktrace","panic","exception","segfault","coredump"]'},
]

GENERIC_NOISE = {
    "file", "files", "document", "documents", "doc", "docs", "folder", "dir",
    "directory", "data", "info", "information", "text", "pdf", "code", "item",
    "thing", "archivo", "archivos", "documento", "documentos", "carpeta",
    "datos", "texto", "search", "query", "result", "results", "note", "notes",
    "list", "record", "records", "form", "page", "copy", "backup",
}

DEFAULT_MODELS = [
    "mlx-community/Qwen3-0.6B-4bit",
    "mlx-community/Qwen3.5-0.8B-4bit",
    "mlx-community/Qwen3.5-2B-4bit",
    "mlx-community/Qwen3.5-2B-8bit",
    "mlx-community/Qwen3.5-4B-4bit",
    "mlx-community/Qwen3.5-4B-8bit",
    "mlx-community/Qwen3.5-9B-4bit",
]

SAMPLE_SHOWCASE_QUERIES = [
    "factura luz",
    "contrato alquiler",
    "login timeout",
    "rate limit",
    "tax return",
]


def strip_accents(s: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c)
    )


def normalize_token(s: str) -> str:
    return strip_accents(s.strip().lower())


def parse_terms(raw: str):
    """Returns (strict_json_ok, list_of_terms)."""
    cleaned = raw.strip()
    # Strip thinking tags if a model emits them despite enable_thinking=False
    cleaned = re.sub(r"<think>.*?</think>", "", cleaned, flags=re.DOTALL).strip()

    try:
        parsed = json.loads(cleaned)
        if isinstance(parsed, list) and all(isinstance(x, str) for x in parsed):
            return True, [x.strip() for x in parsed if x.strip()]
    except Exception:
        pass

    # Fallback extraction if wrapped in ```json ... ``` or prose
    m = re.search(r"\[[^\]]*\]", cleaned, flags=re.DOTALL)
    if m:
        try:
            parsed = json.loads(m.group(0))
            if isinstance(parsed, list):
                return False, [str(x).strip() for x in parsed if str(x).strip()]
        except Exception:
            pass

    return False, []


def build_prompt(tokenizer, query: str, mode: str) -> str:
    user_msg = f"Search mode: {mode}\nQuery: {query}"
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        *FEW_SHOT_TURNS,
        {"role": "user", "content": user_msg},
    ]
    if hasattr(tokenizer, "apply_chat_template"):
        try:
            return tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
        except TypeError:
            return tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
            )
    return f"{SYSTEM_PROMPT}\n\n{user_msg}\nJSON:"


def score_output(query: str, terms: list[str], expected_any: list[str]):
    q_words = set(re.findall(r"[a-z0-9]+", normalize_token(query)))
    norm_expected = [normalize_token(e) for e in expected_any]

    matched_expected = set()
    noise_count = 0
    seen = set()
    useful_terms = []

    for t in terms:
        nt = normalize_token(t)
        if not nt or nt in seen:
            noise_count += 1
            continue
        seen.add(nt)

        words = re.findall(r"[a-z0-9]+", nt)
        is_too_verbose = len(words) > 2 or len(nt) > 28
        is_echo = bool(words) and all(w in q_words for w in words)
        is_generic = nt in GENERIC_NOISE

        if is_too_verbose or is_echo or is_generic:
            noise_count += 1
        else:
            useful_terms.append(t)

        for exp in norm_expected:
            if exp in nt or (len(nt) >= 4 and nt in exp):
                matched_expected.add(exp)

    hit = 1 if len(matched_expected) > 0 else 0
    return {
        "hit": hit,
        "matched_expected_count": len(matched_expected),
        "noise_count": noise_count,
        "total_terms": len(terms),
        "useful_count": len(useful_terms),
    }


def benchmark_model(model_id: str, queries: list[dict], max_tokens: int):
    print(f"\n=== Benchmarking {model_id} ===", flush=True)
    mx.reset_peak_memory()
    t_load0 = time.perf_counter()
    model, tokenizer = load(model_id)
    load_s = time.perf_counter() - t_load0

    sampler = make_sampler(temp=0.0)
    logits_processors = make_logits_processors(repetition_penalty=1.12)

    # Warmup call (compiles Metal graphs / caches)
    warm_prompt = build_prompt(tokenizer, "invoice", "name")
    _ = generate(
        model,
        tokenizer,
        prompt=warm_prompt,
        max_tokens=24,
        sampler=sampler,
        logits_processors=logits_processors,
        verbose=False,
    )
    mx.synchronize()

    latencies_ms = []
    strict_json_hits = 0
    expected_hits = 0
    total_matched_expected = 0
    total_terms = 0
    total_noise = 0
    total_gen_tokens = 0
    samples = {}
    per_category_hits = {}

    for item in queries:
        prompt = build_prompt(tokenizer, item["query"], item["mode"])
        t0 = time.perf_counter()
        raw = generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=sampler,
            logits_processors=logits_processors,
            verbose=False,
        )
        mx.synchronize()
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        latencies_ms.append(elapsed_ms)

        gen_toks = len(tokenizer.encode(raw))
        total_gen_tokens += gen_toks

        strict_ok, terms = parse_terms(raw)
        if strict_ok:
            strict_json_hits += 1

        sc = score_output(item["query"], terms, item["expected_any"])
        expected_hits += sc["hit"]
        total_matched_expected += sc["matched_expected_count"]
        total_terms += sc["total_terms"]
        total_noise += sc["noise_count"]

        cat = item["category"]
        per_category_hits.setdefault(cat, [0, 0])
        per_category_hits[cat][0] += sc["hit"]
        per_category_hits[cat][1] += 1

        if item["query"] in SAMPLE_SHOWCASE_QUERIES:
            samples[item["query"]] = {
                "terms": terms,
                "ms": round(elapsed_ms, 1),
                "strict_json": strict_ok,
                "raw": raw.strip()[:140],
            }

    peak_metal_gb = mx.get_peak_memory() / 1e9
    rss_gb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9  # macOS bytes

    n = len(queries)
    sorted_lat = sorted(latencies_ms)
    p95 = sorted_lat[min(n - 1, int(0.95 * n))]
    median_ms = statistics.median(latencies_ms)
    total_s = sum(latencies_ms) / 1000.0
    tok_per_s = total_gen_tokens / total_s if total_s > 0 else 0.0

    summary = {
        "model": model_id,
        "load_s": round(load_s, 2),
        "peak_metal_gb": round(peak_metal_gb, 2),
        "rss_gb": round(rss_gb, 2),
        "median_ms": round(median_ms, 1),
        "p95_ms": round(p95, 1),
        "tok_per_s": round(tok_per_s, 1),
        "strict_json_pct": round(100.0 * strict_json_hits / n, 1),
        "hit_rate_pct": round(100.0 * expected_hits / n, 1),
        "avg_expected_matches": round(total_matched_expected / n, 2),
        "noise_rate_pct": round(100.0 * total_noise / max(1, total_terms), 1),
        "avg_terms": round(total_terms / n, 1),
        "by_category": {
            k: f"{v[0]}/{v[1]}" for k, v in per_category_hits.items()
        },
        "samples": samples,
    }

    print(
        f"  load={summary['load_s']}s | metal={summary['peak_metal_gb']}GB | "
        f"med={summary['median_ms']}ms p95={summary['p95_ms']}ms ({summary['tok_per_s']} tok/s) | "
        f"JSON={summary['strict_json_pct']}% | Hit={summary['hit_rate_pct']}% "
        f"(avgMatch={summary['avg_expected_matches']}) | Noise={summary['noise_rate_pct']}%",
        flush=True,
    )
    for q in SAMPLE_SHOWCASE_QUERIES:
        if q in samples:
            print(f"    [{q}] ({samples[q]['ms']}ms): {samples[q]['terms']}", flush=True)

    # Free weights cleanly before next model
    del model
    del tokenizer
    gc.collect()
    mx.clear_cache()
    return summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", nargs="+", default=DEFAULT_MODELS)
    parser.add_argument(
        "--queries",
        default=str(Path(__file__).with_name("bench-mlx-queries.json")),
    )
    parser.add_argument("--max-tokens", type=int, default=48)
    parser.add_argument("--output", default="/tmp/arbor_mlx_bench.json")
    args = parser.parse_args()

    queries = json.loads(Path(args.queries).read_text())
    results = []
    for model_id in args.models:
        try:
            res = benchmark_model(model_id, queries, args.max_tokens)
            results.append(res)
            # Persist incrementally after each model so partial runs are never lost
            Path(args.output).write_text(json.dumps(results, indent=2, ensure_ascii=False))
        except Exception as e:
            print(f"ERROR on {model_id}: {e}", file=sys.stderr, flush=True)
            results.append({"model": model_id, "error": str(e)})
            Path(args.output).write_text(json.dumps(results, indent=2, ensure_ascii=False))

    print("\n=== SUMMARY TABLE ===")
    header = f"{'Model':34s} {'Metal':>6s} {'Med':>7s} {'P95':>7s} {'Tok/s':>6s} {'JSON%':>6s} {'Hit%':>6s} {'Match':>5s} {'Noise%':>7s}"
    print(header)
    print("-" * len(header))
    for r in results:
        if "error" in r:
            print(f"{r['model']:34s} ERROR: {r['error']}")
            continue
        short = r["model"].replace("mlx-community/", "")
        print(
            f"{short:34s} {r['peak_metal_gb']:5.2f}G {r['median_ms']:6.1f}m {r['p95_ms']:6.1f}m "
            f"{r['tok_per_s']:6.1f} {r['strict_json_pct']:5.1f}% {r['hit_rate_pct']:5.1f}% "
            f"{r['avg_expected_matches']:5.2f} {r['noise_rate_pct']:6.1f}%"
        )


if __name__ == "__main__":
    main()
