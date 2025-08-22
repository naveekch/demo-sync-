package com.example.demo.api;

import java.util.List;
import java.util.Map;

public class BatchRequest {
    private String batchId;                         // optional
    private String source;                          // optional
    private List<Map<String, Object>> participants; // required

    public BatchRequest() {}

    public String getBatchId() { return batchId; }
    public void setBatchId(String batchId) { this.batchId = batchId; }

    public String getSource() { return source; }
    public void setSource(String source) { this.source = source; }

    public List<Map<String, Object>> getParticipants() { return participants; }
    public void setParticipants(List<Map<String, Object>> participants) { this.participants = participants; }
}