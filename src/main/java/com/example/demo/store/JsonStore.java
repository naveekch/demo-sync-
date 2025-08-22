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

    public synchronized Optional<Map<String,Object>> get(String participantId){
        return Optional.ofNullable(cache.get(participantId));
    }

    public synchronized void put(String participantId, Map<String,Object> doc){
        cache.put(participantId, doc);
    }
}