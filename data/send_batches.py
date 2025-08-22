#!/usr/bin/env python3
"""
Read participants JSON and send to API in batches.

Usage:
  python send_batches.py --api http://localhost:8080/appointments/participants \
                         --infile data/participants_seed.json \
                         --batch-size 200 \
                         --source upstream-python \
                         --batch-prefix 2025-08-21-run

Optional flags:
  --promote-mids <N>    Simulate day-2: choose N records that had no MID, assign a new MID,
                        and (optionally) change participantId to a *different* temp id to
                        exercise the secondary match (firstName+lastName+email).
"""
import argparse, json, math, time, random
from pathlib import Path
import requests

def chunked(seq, size):
    for i in range(0, len(seq), size):
        yield seq[i:i+size]

def simulate_mid_promotions(participants, count):
    """ Assign new MIDs to 'count' participants who previously had no MID.
        Also change participantId to a new temp id to mimic upstream behavior """
    none_mid_idxs = [i for i, p in enumerate(participants) if not p.get("mid")]
    random.shuffle(none_mid_idxs)
    chosen = none_mid_idxs[:min(count, len(none_mid_idxs))]
    for idx in chosen:
        p = participants[idx]
        p["mid"] = f"MID-PROMO-{100000 + idx}"
        p["participantId"] = f"temp-day2-{idx}"  # new temp id coming from upstream
    return len(chosen)

def post_batch(api_url, source, batch_prefix, batch_no, items, timeout=30):
    body = {
        "batchId": f"{batch_prefix}-{batch_no:03d}",
        "source": source,
        "participants": items
    }
    resp = requests.post(api_url, json=body, timeout=timeout)
    return resp

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", type=str, required=True, help="POST endpoint, e.g. http://localhost:8080/appointments/participants")
    ap.add_argument("--infile", type=str, required=True)
    ap.add_argument("--batch-size", type=int, default=200)
    ap.add_argument("--source", type=str, default="upstream-python")
    ap.add_argument("--batch-prefix", type=str, default="run")
    ap.add_argument("--promote-mids", type=int, default=0, help="Simulate assigning MIDs to this many previously-no-MID participants")
    ap.add_argument("--retries", type=int, default=3, help="retries on 5xx/timeouts")
    ap.add_argument("--backoff", type=float, default=1.5, help="exponential backoff base seconds")
    args = ap.parse_args()

    with open(args.infile) as f:
        participants = json.load(f)
    total = len(participants)

    # Optional: simulate day-2 promotions
    promoted = 0
    if args.promote_mids > 0:
        promoted = simulate_mid_promotions(participants, args.promote_mids)
        print(f"Simulated MID promotion on {promoted} participants")

    batches = list(chunked(participants, args.batch_size))
    print(f"Sending {total} participants in {len(batches)} batch(es) of up to {args.batch_size}...")

    created_total = 0
    updated_or_nochange_total = 0
    failed = 0

    for i, batch in enumerate(batches, start=1):
        attempt = 0
        while True:
            attempt += 1
            try:
                resp = post_batch(args.api, args.source, args.batch_prefix, i, batch)
                sc = resp.status_code
                if sc in (201, 204):
                    if sc == 201:
                        created_total += len(batch)  # rough: some may be updates; API doesn't return breakdown
                        print(f"[batch {i:03d}] -> 201 Created")
                    else:
                        updated_or_nochange_total += len(batch)
                        print(f"[batch {i:03d}] -> 204 No Content")
                    break
                else:
                    # 4xx or unexpected code: print body for debugging
                    print(f"[batch {i:03d}] ERROR status={sc} body={resp.text[:500]}")
                    failed += len(batch)
                    break
            except requests.RequestException as e:
                if attempt > args.retries:
                    print(f"[batch {i:03d}] FAILED after retries: {e}")
                    failed += len(batch)
                    break
                sleep_s = args.backoff ** (attempt-1)
                print(f"[batch {i:03d}] transient error: {e} -> retrying in {sleep_s:.1f}s")
                time.sleep(sleep_s)

    print("\n--- summary ---")
    print(f"batches: {len(batches)}")
    print(f"approx created (201 batches): {created_total}")
    print(f"approx updated/no-change (204 batches): {updated_or_nochange_total}")
    print(f"failed: {failed}")

if __name__ == "__main__":
    main()