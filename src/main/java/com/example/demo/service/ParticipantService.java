package com.example.demo.service;


import com.example.demo.api.BatchRequest;
import com.example.demo.api.BulkUpsertResponse;
import com.example.demo.store.JsonStore;
import org.springframework.stereotype.Service;

import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.*;

@Service
public class ParticipantService {
    private final JsonStore store;
    public ParticipantService(JsonStore store){ this.store = store; }

    /** Processes a batch; always succeeds (or throws 400 for bad payload). */
    public void upsertBatch(BatchRequest req){
        if(req.participants == null || req.participants.isEmpty())
            throw new IllegalArgumentException("participants array is required and must be non-empty");

        for(Map<String,Object> item : req.participants){
            String pid = str(item.get("participantId"));
            if(pid == null || pid.isBlank()) {
                // Minimal POC behavior: skip invalid entries silently OR throw.
                // Throwing keeps the contract strict; uncomment to skip instead.
                throw new IllegalArgumentException("participantId is required for every item");
                // continue;
            }

            // Canonicalize in-place
            lowerTrim(item, "email");
            trim(item, "firstName"); trim(item, "lastName"); trim(item, "username");
            trim(item, "phone"); trim(item, "mid"); trim(item, "attendanceStatus");

            // Load existing
            var existingOpt = store.get(pid);
            if(existingOpt.isEmpty()){
                // CREATE
                store.put(pid, item);
                continue;
            }

            Map<String,Object> existing = existingOpt.get();

            // NO-CHANGE? Compare business fields (ignore participantId, batchId, updatedAt)
            if(businessEqual(existing, item)){
                // still propagate updatedAt/batchId if provided
                if(item.containsKey("updatedAt")) existing.put("updatedAt", item.get("updatedAt"));
                if(req.batchId != null) existing.put("batchId", req.batchId);
                store.put(pid, existing);
                continue;
            }

            // UPDATE: shallow merge
            Map<String,Object> merged = new HashMap<>(existing);
            merged.putAll(item);
            if(req.batchId != null) merged.put("batchId", req.batchId);
            store.put(pid, merged);
        }

        store.save();
    }

    /* ---------- helpers ---------- */
    private static boolean businessEqual(Map<String,Object> a, Map<String,Object> b){
        String[] keys = {"username","firstName","lastName","email","phone","mid","attendanceStatus","metadata"};
        for(String k: keys) if(!Objects.equals(a.get(k), b.get(k))) return false;
        return true;
    }
    private static String str(Object o){ return o==null?null:String.valueOf(o); }
    private static void trim(Map<String,Object> m, String k){ Object v=m.get(k); if(v instanceof String s) m.put(k, s.trim()); }
    private static void lowerTrim(Map<String,Object> m, String k){ Object v=m.get(k); if(v instanceof String s) m.put(k, s.trim().toLowerCase()); }
}