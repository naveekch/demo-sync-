package com.example.demo.service;


import com.example.demo.api.BatchRequest;
import com.example.demo.store.JsonStore;
import org.springframework.stereotype.Service;


import java.util.*;

@Service
public class ParticipantService {
    private final JsonStore store;
    public ParticipantService(JsonStore store){ this.store = store; }

    /**
     * Batch upsert with two-level existence check:
     * 1) Try by participantId
     * 2) Else try by (firstName, lastName, email)
     * If secondary matches a different pid, update the matched record IN PLACE (keep original pid).
     * If none matches, create under incoming participantId.
     * MID is normalized (accept "mid"/"MID"/"mId") and always applied when provided.
     *
     * @return true if at least one CREATE happened (controller returns 201), else false (controller returns 204).
     */
    public boolean upsertBatch(BatchRequest req){
        if(req.participants == null || req.participants.isEmpty())
            throw new IllegalArgumentException("participants array is required and must be non-empty");

        boolean createdAny = false;

        for(Map<String,Object> item : req.participants){
            // ---- basic validation ----
            String pid = str(item.get("participantId"));
            if (pid == null || pid.isBlank()) {
                throw new IllegalArgumentException("participantId is required for every item");
            }

            // ---- canonicalize incoming fields ----
            lowerTrim(item, "email");
            trim(item, "firstName"); trim(item, "lastName"); trim(item, "username");
            trim(item, "phone"); trim(item, "attendanceStatus");

            // Normalize MID key/value (accept "mid", "MID", "mId")
            String incomingMid = coalesceMid(item);
            if (incomingMid != null) item.put("mid", incomingMid); // force canonical key

            // Optional: batch metadata for traceability
            if (req.batchId != null) item.put("batchId", req.batchId);
            if (req.source  != null) item.put("source",  req.source);

            // ---- 1) PRIMARY MATCH: by participantId ----
            var byPid = store.get(pid);
            if (byPid.isPresent()) {
                Map<String,Object> existing = byPid.get();

                if (businessEqual(existing, item)) {
                    // no-change; still ensure MID/batch/source are applied if present
                    if (incomingMid != null) existing.put("mid", incomingMid);
                    if (req.batchId != null) existing.put("batchId", req.batchId);
                    if (req.source  != null) existing.put("source",  req.source);
                    store.put(pid, existing);
                } else {
                    Map<String,Object> merged = new HashMap<>(existing);
                    merged.putAll(item);
                    if (incomingMid != null) merged.put("mid", incomingMid);
                    store.put(pid, merged);
                }
                // done with this item
                continue;
            }

            // ---- 2) SECONDARY MATCH: by (firstName, lastName, email) ----
            var byComposite = store.findByNameEmail(
                    str(item.get("firstName")), str(item.get("lastName")), str(item.get("email"))
            );

            if (byComposite.isPresent()) {
                // Found an existing person under a DIFFERENT pid; update THAT record in place.
                var entry = byComposite.get();
                String existingPid = entry.getKey();
                Map<String,Object> existing = entry.getValue();

                if (businessEqual(existing, item)) {
                    if (incomingMid != null) existing.put("mid", incomingMid);
                    if (req.batchId != null) existing.put("batchId", req.batchId);
                    if (req.source  != null) existing.put("source",  req.source);
                    store.put(existingPid, existing);
                } else {
                    Map<String,Object> merged = new HashMap<>(existing);
                    merged.putAll(item);
                    if (incomingMid != null) merged.put("mid", incomingMid);
                    // Keep original pid to avoid duplicate person
                    merged.put("participantId", existingPid);
                    store.put(existingPid, merged);
                }
                continue;
            }

            // ---- 3) CREATE: no match by pid or composite -> new record under incoming pid ----
            store.put(pid, item);
            createdAny = true;
        }

        store.save();
        return createdAny;
    }

    /* ---------- helpers ---------- */

    private static boolean businessEqual(Map<String,Object> a, Map<String,Object> b){
        // Compare meaningful business fields (including mid); ignore participantId, batchId, source
        String[] keys = {"username","firstName","lastName","email","phone","mid","attendanceStatus","metadata"};
        for(String k: keys) if(!Objects.equals(a.get(k), b.get(k))) return false;
        return true;
    }

    private static String str(Object o){ return o==null?null:String.valueOf(o); }

    private static void trim(Map<String,Object> m, String k){
        Object v=m.get(k); if(v instanceof String s) m.put(k, s.trim());
    }
    private static void lowerTrim(Map<String,Object> m, String k){
        Object v=m.get(k); if(v instanceof String s) m.put(k, s.trim().toLowerCase());
    }

    /** Accept "mid", "MID", "mId" and return a trimmed non-blank value; else null. */
    private static String coalesceMid(Map<String,Object> m) {
        for (String k : new String[]{"mid","MID","mId"}) {
            Object v = m.get(k);
            if (v instanceof String s) {
                String t = s.trim();
                if (!t.isEmpty()) return t;
            }
        }
        return null;
    }
}