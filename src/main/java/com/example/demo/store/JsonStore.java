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
    private final Path file = Paths.get("data/participants.json"); // auto-created
    private final ObjectMapper om = new ObjectMapper();

    // participantId -> participantDoc
    private Map<String, Map<String,Object>> cache = new HashMap<>();

    public JsonStore(){ load(); }

    public synchronized void load(){
        try{
            if(Files.exists(file)){
                cache = om.readValue(Files.readString(file),
                        new TypeReference<Map<String, Map<String,Object>>>(){});
            }else{
                cache = new HashMap<>();
            }
        }catch(IOException e){ throw new RuntimeException("Read "+file+" failed", e); }
    }

    public synchronized void save(){
        try{
            Path parent = file.getParent();
            if(parent!=null) Files.createDirectories(parent);
            Files.writeString(file,
                    om.writerWithDefaultPrettyPrinter().writeValueAsString(cache),
                    StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
        }catch(IOException e){ throw new RuntimeException("Write "+file+" failed", e); }
    }

    /** Primary fetch by participantId */
    public synchronized Optional<Map<String,Object>> get(String participantId){
        return Optional.ofNullable(cache.get(participantId));
    }

    /** Update/insert under a specific participantId */
    public synchronized void put(String participantId, Map<String,Object> doc){
        cache.put(participantId, doc);
    }

    /**
     * Secondary lookup by (firstName, lastName, email), case-insensitive/trimmed.
     * Returns the entry (pid + doc) if found, else empty.
     */
    public synchronized Optional<Map.Entry<String, Map<String,Object>>> findByNameEmail(
            String firstName, String lastName, String email) {

        String f = norm(firstName);
        String l = norm(lastName);
        String e = norm(email);

        if (f == null || l == null || e == null) return Optional.empty(); // need all 3

        for (var entry : cache.entrySet()) {
            var doc = entry.getValue();
            if (eq(norm(doc.get("firstName")), f)
                    && eq(norm(doc.get("lastName")), l)
                    && eq(norm(doc.get("email")), e)) {
                return Optional.of(entry);
            }
        }
        return Optional.empty();
    }

    /* ---------- helpers ---------- */
    private static boolean eq(String a, String b){ return Objects.equals(a, b); }
    private static String norm(Object v) {
        if (v == null) return null;
        String s = String.valueOf(v).trim();
        if (s.isEmpty()) return null;
        return s.toLowerCase(); // case-insensitive compare
    }
}