package com.example.demo.api;

import java.util.ArrayList;
import java.util.List;

public class BulkUpsertResponse {
    public String batchId;
    public String status; // completed|partial_failed|failed
    public Counts counts = new Counts();
    public List<ErrorItem> errors = new ArrayList<>();

    public static class Counts {
        public int processed, created, updated, noChange, failed;
    }

    public static class ErrorItem {
        public int index;             // zero-based index in request array
        public String clientRecordId; // if present in input map
        public String participantId;  // if present
        public String code;           // VALIDATION | STALE_UPDATE | UNKNOWN
        public String message;
    }
}