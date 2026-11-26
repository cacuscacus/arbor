#!/usr/bin/env python3
"""
Isolated local MLX term-expansion helper for Arbor (Phase 1d).

Runs as a long-lived child process communicating via line-delimited JSON on stdin/stdout
so quantized MLX weights stay warm in Metal RAM across searches (~230 ms/query on 2B-8bit)
and can be unloaded cleanly by terminating the helper on idle timeout.

Protocol:
  -> {"op": "ping", "id": 1}
  <- {"id": 1, "ok": true, "model": "..."}

  -> {"op": "expand", "id": 2, "query": "factura luz", "mode": "name", "model": "mlx-community/Qwen3.5-2B-8bit", "max_tokens": 48}
  <- {"id": 2, "ok": true, "raw": "[\"electricity\",\"bill\",...]", "elapsed_ms": 225.4, "model": "..."}
"""

import gc
import json
import sys
import time

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

loaded_model_id = None
model = None
tokenizer = None
sampler = make_sampler(temp=0.0)
logits_processors = make_logits_processors(repetition_penalty=1.12)


def emit(payload: dict):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def ensure_model(model_id: str):
    global loaded_model_id, model, tokenizer
    if loaded_model_id == model_id and model is not None and tokenizer is not None:
        return
    if model is not None:
        del model
        del tokenizer
        model = None
        tokenizer = None
        loaded_model_id = None
        gc.collect()
        mx.clear_cache()

    model, tokenizer = load(model_id)
    loaded_model_id = model_id


def build_prompt(tok, query: str, mode: str) -> str:
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        *FEW_SHOT_TURNS,
        {"role": "user", "content": f"Search mode: {mode}\nQuery: {query}"},
    ]
    if hasattr(tok, "apply_chat_template"):
        try:
            return tok.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
        except TypeError:
            return tok.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
            )
    return f"{SYSTEM_PROMPT}\n\nSearch mode: {mode}\nQuery: {query}\nJSON:"


def main():
    global loaded_model_id, model, tokenizer
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req_id = 0
        try:
            req = json.loads(line)
            req_id = req.get("id", 0)
            op = req.get("op", "expand")

            if op == "ping":
                emit({"id": req_id, "ok": True, "model": loaded_model_id})
                continue

            if op == "unload":
                model = None
                tokenizer = None
                loaded_model_id = None
                gc.collect()
                mx.clear_cache()
                emit({"id": req_id, "ok": True})
                continue

            if op == "expand":
                model_id = req["model"]
                query = req["query"]
                mode = req.get("mode", "name")
                max_tokens = int(req.get("max_tokens", 48))

                t0 = time.perf_counter()
                ensure_model(model_id)
                prompt = build_prompt(tokenizer, query, mode)
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
                emit(
                    {
                        "id": req_id,
                        "ok": True,
                        "raw": raw,
                        "elapsed_ms": round(elapsed_ms, 1),
                        "model": loaded_model_id,
                    }
                )
                continue

            emit({"id": req_id, "ok": False, "error": f"Unknown op: {op}"})
        except Exception as e:
            emit({"id": req_id, "ok": False, "error": str(e)})


if __name__ == "__main__":
    main()
