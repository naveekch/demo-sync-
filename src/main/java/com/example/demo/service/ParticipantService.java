package com.example.demo.service;


import com.example.demo.api.BatchRequest;
import com.example.demo.store.JsonStore;
import org.springframework.stereotype.Service;


import java.util.*;

@Service
public class ParticipantService {

    private final JsonStore store;

    public ParticipantService(JsonStore store) {
        this.store = store;
    }

    /**
     * Batch upsert with two-level existence check:
     * 1) Try by participantId
     * 2) Else try by (firstName, lastName, email)
     * If secondary matches a different pid, update the matched record IN PLACE (keep original pid).
     * If none matches, create under incoming participantId.
     * MID is normalized (accept "mid","MID","mId") and always applied when provided.
     *
     * @return true if at least one CREATE (so controller returns 201), else false (controller returns 204).
     */
    public boolean upsertBatch(BatchRequest req) throws Exception {
        List<Map<String, Object>> items = req.getParticipants();
        if (items == null || items.isEmpty()) {
            throw new IllegalArgumentException("participants array is required and must be non-empty");
        }

        boolean createdAny = false;

        for (Map<String, Object> item : items) {
            // Validate
            if (!item.containsKey("participantId")) {
                throw new IllegalArgumentException("participantId is required for every item");
            }

            // Canonicalize basic fields
            lowerTrim(item, "email");
            trim(item, "firstName");
            trim(item, "lastName");
            trim(item, "username");
            trim(item, "phone");
            trim(item, "attendanceStatus");

            // Normalize MID
            String incomingMid = coalesceMid(item);
            if (incomingMid != null) {
                item.put("mid", incomingMid);
            }

            // Attach batch/source for traceability
            if (req.getBatchId() != null) item.put("batchId", req.getBatchId());
            if (req.getSource() != null)  item.put("source",  req.getSource());

            String pid = String.valueOf(item.get("participantId")).trim();
            Map<String, Object> existing = store.get(pid);

            if (existing != null) {
                // Primary match: same pid
                if (businessEqual(existing, item)) {
                    // No business change → still update mid/batch/source if present
                    if (incomingMid != null) existing.put("mid", incomingMid);
                    if (req.getBatchId() != null) existing.put("batchId", req.getBatchId());
                    if (req.getSource() != null)  existing.put("source",  req.getSource());
                    store.put(pid, existing);
                } else {
                    Map<String, Object> merged = new HashMap<String, Object>(existing);
                    merged.putAll(item);
                    if (incomingMid != null) merged.put("mid", incomingMid);
                    store.put(pid, merged);
                }
                continue;
            }

            // Secondary match: by (firstName, lastName, email)
            String fn = safeLower(item.get("firstName"));
            String ln = safeLower(item.get("lastName"));
            String em = safeLower(item.get("email"));
            String existingPid = store.findByNameEmail(fn, ln, em);

            if (existingPid != null) {
                Map<String, Object> found = store.get(existingPid);
                if (businessEqual(found, item)) {
                    if (incomingMid != null) found.put("mid", incomingMid);
                    if (req.getBatchId() != null) found.put("batchId", req.getBatchId());
                    if (req.getSource() != null)  found.put("source",  req.getSource());
                    store.put(existingPid, found);
                } else {
                    Map<String, Object> merged = new HashMap<String, Object>(found);
                    merged.putAll(item);
                    if (incomingMid != null) merged.put("mid", incomingMid);
                    // keep original pid to avoid duplicate person
                    merged.put("participantId", existingPid);
                    store.put(existingPid, merged);
                }
                continue;
            }

            // Create new
            store.put(pid, item);
            createdAny = true;
        }

        store.save();
        return createdAny;
    }

    /* ---------- helpers ---------- */

    private static boolean businessEqual(Map<String, Object> a, Map<String, Object> b) {
        // Compare meaningful business fields (including mid); ignore participantId, batchId, source
        String[] keys = new String[] {
                "username","firstName","lastName","email","phone","mid","attendanceStatus","metadata"
        };
        for (String k : keys) {
            Object va = a.get(k);
            Object vb = b.get(k);
            if (!Objects.equals(va, vb)) return false;
        }
        return true;
    }

    private static void trim(Map<String, Object> m, String k) {
        Object v = m.get(k);
        if (v instanceof String) {
            String s = ((String) v).trim();
            m.put(k, s);
        }
    }

    private static void lowerTrim(Map<String, Object> m, String k) {
        Object v = m.get(k);
        if (v instanceof String) {
            String s = ((String) v).trim().toLowerCase();
            m.put(k, s);
        }
    }

    private static String safeLower(Object v) {
        if (v == null) return null;
        String s = v.toString().trim();
        return s.isEmpty() ? null : s.toLowerCase();
    }

    /** Accept "mid", "MID", "mId" and return trimmed non-blank; else null. */
    private static String coalesceMid(Map<String, Object> m) {
        String[] keys = new String[] {"mid", "MID", "mId"};
        for (String k : keys) {
            Object v = m.get(k);
            if (v != null) {
                String s = v.toString().trim();
                if (!s.isEmpty()) return s;
            }
        }
        return null;
    }
}