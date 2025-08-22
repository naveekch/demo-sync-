#!/usr/bin/env python3
"""
Generate a JSON file of fake participants for POC.

Usage:
  python generate_participants.py --count 1000 --outfile data/participants_seed.json --event event-1001 --mid-ratio 0.7
"""
import argparse, json, os, random, string
from pathlib import Path

FIRST = ["John","Ava","Noah","Mia","Ethan","Ella","Liam","Zoe","Lucas","Ivy","Aria","Leo","Nora","Jack","Lily"]
LAST  = ["Doe","Smith","Johnson","Brown","Taylor","Lee","Martin","Davis","Clark","Walker","Young","White","Hall","King","Allen"]
STATUSES = ["Registered","Checked_In","No_Show","Cancelled"]

def rand_phone():
    # simple fake phone format
    return f"+1-555-{random.randint(100,999)}-{random.randint(1000,9999)}"

def rand_username(first, last, n):
    return f"{first[0].lower()}{last.lower()}{n}"

def slug(n):
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=n))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=500)
    ap.add_argument("--outfile", type=str, default="data/participants_seed.json")
    ap.add_argument("--event", type=str, default="event-1001")
    ap.add_argument("--mid-ratio", type=float, default=0.7, help="fraction [0..1] that have a MID on day 1")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    random.seed(args.seed)
    Path(os.path.dirname(args.outfile) or ".").mkdir(parents=True, exist_ok=True)

    participants = []
    for i in range(args.count):
        first = random.choice(FIRST)
        last  = random.choice(LAST)
        email = f"{first}.{last}.{i}@example.com".lower()
        has_mid = random.random() < args.mid_ratio

        if has_mid:
            mid = f"MID-{100000 + i}"
            participant_id = f"mid-{100000 + i}"  # upstream uses MID as participantId when known
        else:
            mid = None
            participant_id = f"temp-{slug(6)}"    # upstream uses temp id when MID unknown

        participants.append({
            "participantId": participant_id,
            "firstName": first,
            "lastName": last,
            "email": email,
            "phone": rand_phone(),
            "mid": mid,
            "username": rand_username(first, last, i),
            "attendanceStatus": random.choice(STATUSES),
            "metadata": {
                "eventId": args.event
            }
        })

    with open(args.outfile, "w") as f:
        json.dump(participants, f, indent=2)

    print(f"Wrote {len(participants)} participants → {args.outfile}")

if __name__ == "__main__":
    main()