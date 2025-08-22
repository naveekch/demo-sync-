package com.example.demo.api;

import com.example.demo.service.ParticipantService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/appointments/participants")
public class ParticipantController {

    private final ParticipantService service;

    public ParticipantController(ParticipantService service) {
        this.service = service;
    }

    @PostMapping(consumes = "application/json")
    public ResponseEntity<Void> upsertBatch(@RequestBody BatchRequest request) {
        try {
            boolean createdAny = service.upsertBatch(request);
            return createdAny
                    ? ResponseEntity.status(201).build()   // at least one new record
                    : ResponseEntity.noContent().build();  // only updates / no-change
        } catch (IllegalArgumentException ex) {
            return ResponseEntity.badRequest().build(); // missing participantId / empty batch
        } catch (Exception ex) {
            return ResponseEntity.status(500).build();
        }
    }
}