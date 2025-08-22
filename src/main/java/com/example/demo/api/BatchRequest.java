package com.example.demo.api;

import java.util.List;
import java.util.Map;

public class BatchRequest {
    public String batchId;
    public String source;

    // Each participant is just a Map<String,Object>.
    // Required fields for our logic: participantId (String), updatedAt (RFC3339 String, optional)
    public List<Map<String, Object>> participants;
}
