package com.example.demo.store;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Repository;

import java.io.IOException;
import java.nio.file.*;
import java.util.*;

// Generic JSON store: eventId -> participantId -> participantMap
@Repository
public class JsonStore {

    private final Path file = Paths.get("data/participants.json");
    private final ObjectMapper om = new ObjectMapper();

    // participantId -> participantDoc
    private Map<String, Map<String, Object>> cache = new HashMap<>();

    public JsonStore() {
        load();
    }

    public synchronized void load() {
        try {
            if (Files.exists(file)) {
                String content = new String(Files.readAllBytes(file));
                cache = om.readValue(content, new TypeReference<Map<String, Map<String, Object>>>() {});
            } else {
                cache = new HashMap<String, Map<String, Object>>();
            }
        } catch (IOException e) {
            throw new RuntimeException("Failed to read " + file, e);
        }
    }

    public synchronized void save() {
        try {
            Path parent = file.getParent();
            if (parent != null) Files.createDirectories(parent);
            String json = om.writerWithDefaultPrettyPrinter().writeValueAsString(cache);
            Files.write(file, json.getBytes(), StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
        } catch (IOException e) {
            throw new RuntimeException("Failed to write " + file, e);
        }
    }

    /** Primary fetch by participantId; returns null if missing. */
    public synchronized Map<String, Object> get(String participantId) {
        return cache.get(participantId);
    }

    /** Insert/update under a specific participantId. */
    public synchronized void put(String participantId, Map<String, Object> doc) {
        cache.put(participantId, doc);
    }

    /**
     * Secondary lookup by (firstName, lastName, email), case-insensitive/trimmed.
     * Returns the existing participantId if found; otherwise null.
     */
    public synchronized String findByNameEmail(String firstName, String lastName, String email) {
        String f = norm(firstName);
        String l = norm(lastName);
        String e = norm(email);
        if (f == null || l == null || e == null) return null;

        for (Map.Entry<String, Map<String, Object>> entry : cache.entrySet()) {
            Map<String, Object> doc = entry.getValue();
            if (eq(norm(doc.get("firstName")), f) &&
                    eq(norm(doc.get("lastName")), l) &&
                    eq(norm(doc.get("email")), e)) {
                return entry.getKey();
            }
        }
        return null;
    }

    /* ---------- helpers ---------- */
    private static boolean eq(String a, String b) {
        if (a == null && b == null) return true;
        if (a == null || b == null) return false;
        return a.equals(b);
    }

    private static String norm(Object v) {
        if (v == null) return null;
        String s = String.valueOf(v).trim();
        if (s.isEmpty()) return null;
        return s.toLowerCase();
    }
}