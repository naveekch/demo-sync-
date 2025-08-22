# Participants Batch UPSERT – POC

This is a **proof-of-concept** for ingesting **appointment participants** from an upstream system in **batches**. It simulates the actual implementation as closely as possible while keeping the code small and easy to run.

---

## What we’re trying to do

- Accept **batches** of participant records from an upstream app (their side is a Python job that reads from Postgres).
- For each participant:
    - If it **doesn’t exist** → **create** it.
    - If it **exists and changed** → **update** it.
    - If it **exists and is identical** → **no-op**.
- Handle real-world identity issues:
    - Upstream may initially send a **temporary participantId** when they don’t know our **MID**.
    - Later they discover the **MID** and send an “update” that might use a **different participantId**.
    - We **dedupe** by a secondary match on `(firstName, lastName, email)` and **apply MID** when we see it.
- Return **201 Created** if the batch created **any** new records, otherwise **204 No Content**.
- Persist state to a **JSON file** instead of a DB (so the demo is self-contained).

This mirrors the production shape (bulk input + upsert semantics + id rules), just swapping the DB for a JSON file.

---

### Two-step identity check (important!)
1) **Primary**: match by `participantId`
2) **Secondary**: if not found, match by **(firstName, lastName, email)** (case-insensitive)
- If secondary matches, we update the matched record **in place** (keep its original `participantId`), and **always set `mid` if provided**.
- If neither matches → create a **new** record under the incoming `participantId`.

This handles the “day-1 temp id, day-2 MID” scenario without creating duplicates.

---

## Assumptions & constraints (POC vs production)

- POC uses a single JSON file (`data/participants.json`).
- No concurrency controls beyond the JVM lock.
- No idempotency keys.
- Secondary match requires all three fields: `firstName`, `lastName`, `email`.
- Strings are canonicalized: names trimmed, emails lowercased.
- Always apply `mid` when present (`mid`, `MID`, or `mId`).
- Response is minimal:
    - **201 Created** → at least one new participant was added.
    - **204 No Content** → all participants already existed or were updated.
- No per-item results returned.

---
## API

### Endpoint
POST /appointments/participants


### Request body (batch)
```json
{
  "batchId": "batch-20250821-001",
  "source": "upstream-python-script",
  "participants": [
    {
      "participantId": "temp-001",
      "firstName": "John",
      "lastName": "Doe",
      "email": "john.doe@example.com",
      "phone": "123-456-7890",
      "mid": null,
      "username": "johnd",
      "attendanceStatus": "Registered",
      "metadata": { "eventId": "event-1001" }
    },
    {
      "participantId": "mid-5555",
      "firstName": "Alice",
      "lastName": "Smith",
      "email": "alice.smith@example.com",
      "phone": "987-654-3210",
      "mid": "MID-5555",
      "username": "alices",
      "attendanceStatus": "Registered",
      "metadata": { "eventId": "event-1001" }
    }
  ]
}
```
### Responses

201 Created → At least one participant in the batch was newly inserted.

204 No Content → All participants in the batch were either updates or no-ops.

400 Bad Request → The participants array is empty, or an item is missing participantId.


-----
# Participants Batch UPSERT – POC

This repository is a **proof-of-concept** for ingesting **appointment participants** from an upstream system in **batches**, without using a real database.  
It simulates the actual implementation closely, while keeping things small and self-contained.

---

## Data persistence (no DB)

We use a **file-backed store**:

- In-memory `Map<String, Map<String,Object>>` keyed by `participantId`.
- Periodically written to `data/participants.json`.
- On first run: the file/folder is auto-created.
- Secondary lookups scan the in-memory map to find a match by `(firstName, lastName, email)`.

**Example (after a few calls):**

```json
{
  "temp-001": {
    "participantId": "temp-001",
    "firstName": "John",
    "lastName": "Doe",
    "email": "john.doe@example.com",
    "phone": "123-456-7890",
    "mid": "MID-4242",
    "username": "johnd",
    "attendanceStatus": "Registered",
    "metadata": { "eventId": "event-1001" },
    "batchId": "batch-20250821-001",
    "source": "upstream-python-script"
  },
  "mid-5555": {
    "participantId": "mid-5555",
    "firstName": "Alice",
    "lastName": "Smith",
    "email": "alice.smith@example.com",
    "phone": "987-654-3210",
    "mid": "MID-5555",
    "username": "alices",
    "attendanceStatus": "Registered",
    "metadata": { "eventId": "event-1001" },
    "batchId": "batch-20250821-001",
    "source": "upstream-python-script"
  }
}
```
## Generate sample data

```bash
python generate_participants.py \
  --count 1000 \
  --outfile data/participants_seed.json \
  --event event-1001 \
  --mid-ratio 0.7=
```
This creates a JSON file (participants_seed.json) with 1000 sample participants,
70% of which have a mid assigned.
## send batches

```bash
python send_batches.py \
  --api http://localhost:8080/appointments/participants \
  --infile data/participants_seed.json \
  --batch-size 200 \
  --source upstream-python \
  --batch-prefix 2025-08-21-run

```

## Batch behavior

- Data is split into batches of **200** or any size.
- Each batch is posted to the API endpoint: `/appointments/participants`.
- On first send:
    - Expect many **201 Created** responses (new participants added).
- On re-sending the same data:
    - Expect **204 No Content** (records already exist or were updated).


---

